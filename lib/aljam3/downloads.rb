# frozen_string_literal: true

require_relative "worker"

module Aljam3
  # UI-thread state, a single background transfer, and a durable queue in SQLite.
  class Downloads
    attr_reader :entries

    def initialize(store:, downloader:)
      @store, @downloader = store, downloader
      @worker, @progress = Worker.new, Queue.new
      @entries = store.downloads
      @entries.to_a.each do |id, entry|
        if entry[:status] == :cancelling
          finish_stop(id, :cancelled)
          next
        end
        entry[:status] = :paused if entry[:status] == :pausing
        entry[:status] = @store.downloaded?(id) ? :done : :queued if entry[:status] == :downloading
        persist(id)
      end
    end

    def enqueue(book)
      id = book.fetch("id")
      return if @store.downloaded?(id) || %i[queued downloading pausing cancelling].include?(@entries.dig(id, :status))

      @store.cache_books([book])
      @entries[id] = { fraction: 0, queued_at: Time.now.utc.iso8601(6), **(@entries[id] || {}),
        book:, status: :queued, message: "في قائمة الانتظار" }
      persist(id)
    end

    def pause(id) = stop(id, :paused)
    def cancel(id) = stop(id, :cancelled)

    def remove(id)
      raise "Wait for the transfer to stop." if @active == id

      @downloader.remove(id)
      @entries.delete(id)
      @store.forget_download(id)
    end

    # Structural changes redraw the screen; progress updates change controls in place.
    def tick
      @changed = false
      until @progress.empty?
        id, fraction, message, bytes, total = @progress.pop
        next unless @entries.dig(id, :status) == :downloading

        @entries.fetch(id).merge!(fraction:, message:, bytes:, total:)
        persist(id)
      end
      @worker.drain
      start_next unless @active
      @changed
    end

    def close
      if @active
        pending_stop = @stop
        @stop ||= :paused
        @worker.close
        if pending_stop
          finish_stop(@active, pending_stop)
        else
          @entries.fetch(@active)[:status] = :queued
          persist(@active)
        end
      else
        @worker.close
      end
    end

    private

    def persist(id) = @store.save_download(id, @entries.fetch(id))

    def stop(id, state)
      if @active == id
        @stop = state
        @entries.fetch(id).merge!(status: state == :paused ? :pausing : :cancelling, message: "جارٍ إيقاف التنزيل…")
      else
        finish_stop(id, state)
      end
      persist(id) if @entries.key?(id)
    end

    def finish_stop(id, state)
      if state == :cancelled
        @downloader.cancel(id)
        @entries.delete(id)
        @store.forget_download(id)
      else
        @entries.fetch(id).merge!(status: :paused, message: "متوقف مؤقتًا · يمكنك المتابعة لاحقًا")
        persist(id)
      end
    end

    def start_next
      id = @entries.find { |_, entry| entry[:status] == :queued }&.first
      return unless id

      @active, @stop = id, nil
      @entries.fetch(id).merge!(status: :downloading, message: "جارٍ تجهيز الكتاب…")
      persist(id)
      @changed = true
      check = -> { raise DownloadStopped if @stop }
      @worker.submit(-> { @downloader.call(id, check:) { |*progress| @progress << [id, *progress] } }) do |_book, error|
        if @store.downloaded?(id)
          bytes = @downloader.disk_usage(id)
          @entries.fetch(id).merge!(status: :done, fraction: 1, message: "اكتمل · متاح دون اتصال", bytes:, total: bytes)
          persist(id)
        elsif @stop
          finish_stop(id, @stop)
        else
          message = case error
                    when ConnectionError then "انقطع الاتصال. أعد المحاولة لمتابعة التنزيل."
                    when Errno::ENOSPC then "المساحة غير كافية. حرّر مساحة ثم تابع التنزيل."
                    else "تعذّر إكمال التنزيل. أعد المحاولة أو ألغِ التنزيل للبدء من جديد."
                    end
          @entries.fetch(id).merge!(status: :failed, message:)
          persist(id)
        end
        @active = nil
        @changed = true
      end
    end
  end
end
