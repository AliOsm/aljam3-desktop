# frozen_string_literal: true

module Aljam3
  # One visible notice; repeated outcomes share a queue entry, even for large batches.
  class Notifications
    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock, @entries = clock, []
      @updated_at = @clock.call
    end

    def current = @entries.first
    def find(key) = @entries.find { |entry| entry[:key] == key }

    def push(key, persistent: false)
      previous = find(key)
      count = previous ? previous.fetch(:count) + 1 : 1
      entry = { key:, count:, remaining: persistent ? nil : 5.0, **yield(count) }
      previous ? @entries[@entries.index(previous)] = entry : @entries << entry
      @updated_at = @clock.call
      entry
    end

    def dismiss(key = current&.fetch(:key))
      @entries.reject! { |entry| entry[:key] == key }
      @updated_at = @clock.call
    end

    def tick(paused: false)
      now = @clock.call
      elapsed, @updated_at = now - @updated_at, now
      return unless current && current[:remaining] && !paused

      current[:remaining] -= elapsed
      dismiss if current[:remaining] <= 0
    end
  end
end
