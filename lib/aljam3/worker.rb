# frozen_string_literal: true

module Aljam3
  # Work happens off the UI thread; callbacks are delivered by the UI's timer.
  class Worker
    def initialize
      @jobs, @events = Queue.new, Queue.new
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

    def submit(work, &callback) = @jobs.push([work, callback])

    def drain
      until @events.empty?
        callback, result, error = @events.pop
        callback.call(result, error)
      end
    end

    def close
      @jobs.close
      @thread.kill.join
    end
  end
end
