# frozen_string_literal: true

require_relative "worker"

module Aljam3
  # SQLite owns the queue. Only the current transfer lives in memory.
  class Downloads
    def initialize(store:, downloader:)
      @store, @downloader = store, downloader
      @worker, @cleanup, @progress = Worker.new, Worker.new, Queue.new
      @store.recover_downloads.each { |id| finish_stop(id, :cancelled) }
    end

    def entries(**options) = @store.downloads(**options)
    def entry(id) = @active == id ? @entry : @store.download(id)

    def enqueue(book)
      id = book.fetch("id")
      previous = entry(id)
      return if @store.downloaded?(id) || %i[queued downloading pausing cancelling].include?(previous&.fetch(:status))

      @store.cache_books([book])
      @store.save_download(id, { fraction: 0, queued_at: Time.now.utc.iso8601(6), **(previous || {}),
        book:, status: :queued, message: "في قائمة الانتظار" })
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
      @cleanup.close
    end

    private

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
        return if @closing

        @cleanup.submit(-> { @downloader.cancel(id); @store.forget_download(id) }) do |_result, error|
          @store.save_download(id, entry(id).merge(status: :failed, message: "تعذّر إلغاء التنزيل. حاول مرة أخرى.")) if error
          @changed = true
        end
      else
        @store.save_download(id, entry(id).merge(status: :paused, message: "متوقف مؤقتًا · يمكنك المتابعة لاحقًا"))
      end
    end

    def start_next
      id = @store.next_download
      return unless id

      @entry = @store.download(id).merge(status: :downloading, message: "جارٍ تجهيز الكتاب…")
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
        @active = @entry = nil
        @progress_dirty = false
        @changed = true
      end
    end
  end
end
