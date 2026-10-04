# frozen_string_literal: true

module Aljam3
  # Keeps the current view alive during data refreshes. Replaced views stop
  # receiving input immediately and leave from their current native position.
  class ViewTransition
    def initialize(motion, group:, overlay: false, &settled)
      @motion, @group, @overlay, @settled = motion, group, overlay, settled
      @current, @leaving = nil, []
    end

    attr_reader :current

    def views = [@current, *@leaving].compact

    def replace(direction: nil)
      return yield(@current) if @current && direction.nil?

      previous = @current
      previous.inert = true if previous
      @current = yield(nil)
      if previous && !@motion.reduced
        @leaving << previous
        @current.style(opacity: 0.0, displace_left: direction)
        if @overlay
          # The incoming opaque page supplies both crossfade weights. Freeze
          # the displayed composition beneath it, including interrupted fades.
          @motion.cancel(@group)
          @leaving.each { |view| view.overlay = false }
          @current.overlay = true
          @motion.to(@current, opacity: 1.0, duration: 0.16, group: @group, complete: -> {
            @leaving.each(&:remove)
            @leaving.clear
            @current.overlay = false
          })
        else
          @motion.to(previous, opacity: 0.0, displace_left: -direction, duration: 0.16, group: @group,
            complete: -> { previous.remove; @leaving.delete(previous); @settled&.call })
          @motion.to(@current, opacity: 1.0, displace_left: 0, duration: 0.16, group: @group)
        end
      else
        previous&.remove
        @current.style(opacity: 1.0, displace_left: 0)
      end
      @current
    end

    def clear
      @motion.cancel(@group)
      views.each(&:remove)
      @current, @leaving = nil, []
    end
  end
end
