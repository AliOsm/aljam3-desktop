# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class WorkerTest < Minitest::Test
  def test_reporting_keeps_errors_and_callbacks_on_the_calling_thread
    events, failure = [], Aljam3::ResponseError.new(503)
    owner = Thread.current
    worker = Aljam3::Worker.new(on_error: ->(error) { events << [:error, error, Thread.current]; raise "reporting failed" },
      on_activity: ->(state) { events << [state, Thread.current] })
    worker.submit(-> { raise failure }) { |_result, error| events << [:callback, error, Thread.current] }
    _out, stderr = capture_io do
      Timeout.timeout(2) do
        while worker.busy?
          worker.drain
          sleep 0.001
        end
      end
    end
    assert_equal [:started, :error, :failed, :callback], events.map(&:first)
    assert events.all? { |event| event.last.equal?(owner) }
    assert_same failure, events.last[1]
    assert_includes stderr, "Worker diagnostics: RuntimeError"
  ensure
    worker&.close
  end
end
