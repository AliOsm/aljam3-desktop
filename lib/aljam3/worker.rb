# frozen_string_literal: true

module Aljam3
  # Work happens off the UI thread; callbacks are delivered by the UI's timer.
  class Worker
    def initialize(on_error: nil, on_activity: nil)
      @on_error, @on_activity = on_error, on_activity
      @jobs, @events = Queue.new, Queue.new
      @pending = 0
      @thread = Thread.new do
        while (job = @jobs.pop)
          work, callback = job
          begin
            result = work.call
            @events << [callback, result, nil]
          rescue StandardError => error
            @events << [callback, nil, error]
          ensure
            work = callback = result = job = nil
          end
        end
      end
    end

    def submit(work, &callback)
      observe(@on_activity, :started)
      @pending += 1
      @jobs.push([work, callback])
    end

    def busy? = @pending.positive?

    def drain
      until @events.empty?
        callback, result, error = @events.pop
        @pending -= 1
        observe(@on_error, error) if error
        observe(@on_activity, error ? :failed : :completed)
        callback.call(result, error)
      end
    end

    def close
      @jobs.close
      @thread.kill.join
    end

    private

    def observe(callback, value)
      callback&.call(value)
    rescue StandardError => error
      warn "Worker diagnostics: #{error.class}"
    end
  end
end
