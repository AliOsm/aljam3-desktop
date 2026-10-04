# frozen_string_literal: true

require_relative "../motion"

module Aljam3
  module UI
    module Motion
      MOTION_CHOICES = { "system" => "حسب إعدادات النظام", "full" => "مفعّلة", "reduced" => "تقليل الحركة" }.freeze

      def setup_motion
        @motion = Aljam3::Motion.new(driver: Shoes::DisplayService.display_service)
        @motion_preference = @store.preference("motion", "system")
        refresh_motion_preference
      end

      def refresh_motion_preference
        @motion.reduced = @motion_preference == "reduced" || (@motion_preference == "system" && reduced_motion?)
      end

      def choose_motion(value)
        @motion_preference = value
        @store.save_preference("motion", value)
        refresh_motion_preference
      end

      def draw_motion_settings
        para "تتبع الحركة إعدادات تسهيلات الاستخدام في النظام تلقائيًا.", size: 14, stroke: muted
        row(top: 40, height: 40) do
          para "الحركة", width: 72, size: 16
          @dialog_first = dropdown(MOTION_CHOICES, selected: @motion_preference, key: :motion, width: -72) { |value| choose_motion(value) }
        end
      end

      def motion_group
        @drawing_notification ? :feedback : @drawing_dialog ? :dialog : :content
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
