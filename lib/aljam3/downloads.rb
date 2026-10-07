# frozen_string_literal: true

require_relative "worker"

module Aljam3
  # SQLite owns the queue. Only the current transfer lives in memory.
  class Downloads
    def initialize(store:, downloader:, &on_finish)
      @store, @downloader = store, downloader
      @on_finish = on_finish
      @worker, @cleanup, @progress = Worker.new, Worker.new, Queue.new
      @store.recover_downloads
      repair_sizes
    end

    def entries(**options) = @store.downloads(**options)
    def entry(id) = @active == id ? @entry : @store.download(id)
    def current = @entry

    def enqueue_category(category, book_ids) = @store.queue_category_download(category, book_ids)

    def pause_category(id)
      @store.pause_category_download(id)
      pause(@active) if @entry&.dig(:category_id) == id && @entry[:status] == :downloading
    end

    def resume_category(category, failed_only: false)
      ids = @store.category_download_book_ids(category.fetch("id"), states: failed_only ? ["failed"] : nil)
      @store.retry_category_cancellations(category.fetch("id"))
      enqueue_category(category, ids)
      clean_cancellations
    end

    def cancel_category(id)
      @store.cancel_category_download(id)
      cancel(@active) if @entry&.dig(:category_id) == id && !@store.downloaded?(@active)
      clean_cancellations
    end

    def enqueue(book)
      id = book.fetch("id")
      previous = entry(id)
      return if @store.downloaded?(id) || %i[queued downloading pausing cancelling].include?(previous&.fetch(:status))

      @store.cache_books([book])
      @store.save_download(id, { fraction: 0, queued_at: Time.now.utc.iso8601(6), **(previous || {}),
        book:, status: :queued, failure: nil, message: "في قائمة الانتظار" })
      true
    end

    def pause(id) = stop(id, :paused)
    def cancel(id) = stop(id, :cancelled)

    def remove(id)
      raise "Wait for the transfer to stop." if @active == id

      @downloader.remove(id)
      @store.forget_download(id)
    end

    # Structural changes redraw the screen; progress updates change controls in place.
    def tick
      @changed = false
      until @progress.empty?
        id, fraction, message, bytes, total = @progress.pop
        next unless id == @active && @entry[:status] == :downloading

        @entry.merge!(fraction:, message:, bytes:, total:)
        @progress_dirty = true
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @progress_dirty && now - @progress_saved_at >= 1
        persist
        @progress_dirty, @progress_saved_at = false, now
      end
      @worker.drain
      @cleanup.drain
      clean_cancellations
      start_next unless @active
      @changed
    end

    def close
      @closing = true
      if @active
        pending_stop = @stop
        @stop ||= :paused
        @worker.close
        if pending_stop
          finish_stop(@active, pending_stop)
        else
          @entry[:status] = :queued
          persist
        end
      else
        @worker.close
      end
    ensure
      @cleanup.close
    end

    private

    def repair_sizes(after: 0)
      @cleanup.submit(-> { @downloader.repair_download_sizes(after:) }) do |last_id, _error|
        if last_id
          @changed = true
          repair_sizes(after: last_id)
        end
      end
    end

    def persist = @store.save_download(@active, @entry)

    def stop(id, state)
      if @active == id
        @stop = state
        @entry.merge!(status: state == :paused ? :pausing : :cancelling, message: "جارٍ إيقاف التنزيل…")
        persist
      else
        finish_stop(id, state)
      end
    end

    def finish_stop(id, state)
      if state == :cancelled
        @store.save_download(id, entry(id).merge(status: :cancelling, message: "جارٍ إلغاء التنزيل…"))
        clean_cancellations
      else
        @store.save_download(id, entry(id).merge(status: :paused, message: "متوقف مؤقتًا · يمكنك المتابعة لاحقًا"))
      end
    end

    def clean_cancellations
      return if @closing || @cleaning

      ids = @store.cancelling_downloads(except: @active)
      return if ids.empty?

      @cleaning = true
      @cleanup.submit(-> do
        ids.filter_map do |id|
          begin
            @downloader.cancel(id)
            @store.forget_download(id)
            nil
          rescue StandardError
            failed = @store.download(id).merge(status: :failed, failure: "cancel", message: "تعذّر إلغاء التنزيل. حاول مرة أخرى.",
              category_id: @store.download_category_id(id))
            @store.save_download(id, failed)
            failed
          end
        end
      end) do |failures, error|
        @cleaning = false
        warn error.full_message if error
        failures&.each { |failed| @on_finish&.call(failed) }
        @changed = true
      end
    end

    def start_next
      id = @store.next_download
      return unless id

      @entry = @store.download(id).merge(status: :downloading, message: "جارٍ تجهيز الكتاب…", category_id: @store.download_category_id(id))
      @active, @stop = id, nil
      @progress_dirty, @progress_saved_at = false, 0
      persist
      @changed = true
      check = -> { raise DownloadStopped if @stop }
      @worker.submit(-> { @downloader.call(id, check:) { |*progress| @progress << [id, *progress] } }) do |_book, error|
        if @store.downloaded?(id)
          @entry.merge!(status: :done, fraction: 1, message: "اكتمل · متاح دون اتصال")
          persist
        elsif @stop
          finish_stop(id, @stop)
        else
          message = case error
                    when ConnectionError then "انقطع الاتصال. أعد المحاولة لمتابعة التنزيل."
                    when Errno::ENOSPC then "المساحة غير كافية. حرّر مساحة ثم تابع التنزيل."
                    else "تعذّر إكمال التنزيل. أعد المحاولة أو ألغِ التنزيل للبدء من جديد."
                    end
          @entry.merge!(status: :failed, message:)
          persist
        end
        @on_finish&.call(@entry.dup) if %i[done failed].include?(@entry[:status])
        @active = @entry = nil
        @progress_dirty = false
        @changed = true
      end
    end
  end
end
