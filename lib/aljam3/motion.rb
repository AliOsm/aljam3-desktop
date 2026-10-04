# frozen_string_literal: true

module Aljam3
  # One clock and one timer for all active transitions. Retarget from the displayed
  # value, never an old destination; an idle interface has no animation timer.
  class Motion
    def initialize(clock:, schedule:)
      @clock, @schedule = clock, schedule
      @jobs = {}
      @reduced = false
    end

    attr_reader :reduced

    def to(view, duration:, group:, complete: nil, **values)
      key = [view, values.keys.sort]
      return if @jobs[key]&.fetch(:values) == values

      from = values.to_h { |property, target| [property, view.style.fetch(property, target).to_f] }
      @jobs.delete(key)
      if @reduced || duration.zero? || from == values
        view.style(**values)
        complete&.call
        stop_if_idle
        return
      end
      @jobs[key] = { view:, from:, values:, duration:, group:, complete:, started: @clock.call }
      @timer ||= @schedule.call { tick }
    end

    def tick
      now = @clock.call
      @jobs.dup.each do |key, job|
        next unless @jobs[key].equal?(job)

        elapsed = ((now - job.fetch(:started)) / job.fetch(:duration)).clamp(0.0, 1.0)
        amount = 1 - (1 - elapsed)**3
        values = job.fetch(:values).to_h do |property, target|
          start = job.fetch(:from).fetch(property)
          [property, elapsed == 1 ? target : start + (target - start) * amount]
        end
        job.fetch(:view).style(**values)
        if elapsed == 1
          @jobs.delete(key)
          job[:complete]&.call
        end
      end
      stop_if_idle
    end

    def reduced=(value)
      @reduced = value
      return unless value

      @jobs.dup.each do |key, job|
        next unless @jobs.delete(key).equal?(job)

        job.fetch(:view).style(**job.fetch(:values))
        job[:complete]&.call
      end
      stop_if_idle
    end

    def cancel(group = nil)
      group ? @jobs.delete_if { |_key, job| job[:group] == group } : @jobs.clear
      stop_if_idle
    end

    def active?
      !@jobs.empty?
    end

    private

    def stop_if_idle
      return if active?

      @timer&.remove
      @timer = nil
    end
  end
end
