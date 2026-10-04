# frozen_string_literal: true

module Aljam3
  # Owns destinations and lifecycle; the native renderer owns frame timing.
  # Navigation cancels obsolete jobs, and reduced motion completes immediately.
  class Motion
    def initialize(driver:)
      @driver, @jobs, @reduced = driver, {}, false
    end

    attr_reader :reduced

    def to(view, duration:, group:, complete: nil, **values)
      key = [view, values.keys.sort]
      return if @jobs[key]&.fetch(:values) == values

      @jobs.keys.select { |target, properties| target.equal?(view) && (properties & values.keys).any? }.each { cancel_job(_1) }
      if @reduced || duration.zero?
        view.style(**values)
        complete&.call
        return
      end
      job = { view:, values:, group:, complete: }
      @jobs[key] = job
      job[:token] = @driver.transition(view, duration:, **values) do
        next unless @jobs[key].equal?(job)

        @jobs.delete(key)
        complete&.call
      end
    end

    def reduced=(value)
      @reduced = value
      return unless value

      @jobs.dup.each do |key, job|
        next unless @jobs[key].equal?(job)

        cancel_job(key)
        job.fetch(:view).style(**job.fetch(:values))
        job[:complete]&.call
      end
    end

    def cancel(group = nil)
      @jobs.keys.select { |key| group.nil? || @jobs.fetch(key)[:group] == group }.each { cancel_job(_1) }
    end

    def active?
      !@jobs.empty?
    end

    private

    def cancel_job(key)
      @driver.cancel_transition(@jobs.delete(key).fetch(:token))
    end
  end
end
