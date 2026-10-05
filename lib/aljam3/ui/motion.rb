# frozen_string_literal: true

require_relative "../motion"
require_relative "../view_transition"

module Aljam3
  module UI
    module Motion
      def setup_motion
        @motion = Aljam3::Motion.new(driver: Shoes::DisplayService.display_service)
        refresh_motion_preference
      end

      def refresh_motion_preference
        @motion.reduced = reduced_motion?
      end

      def motion_group
        @drawing_notification ? :feedback : @drawing_dialog ? :dialog : @drawing_chrome ? :chrome : :content
      end

      def animate_hover(control)
        group = motion_group
        control.hover { @motion.to(control, hover_amount: 1.0, duration: 0.10, group:) }
        control.leave { @motion.to(control, hover_amount: 0.0, duration: 0.10, group:) }
      end

      def smooth_progress(view, fraction, group: :content)
        @motion.to(view, fraction: fraction.clamp(0.0, 1.0), duration: 0.16, group:)
      end
    end
  end
end
