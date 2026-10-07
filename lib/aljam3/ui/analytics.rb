# frozen_string_literal: true

require_relative "../analytics"

module Aljam3
  module UI
    module UsageAnalytics
      def setup_analytics(directory)
        # CI, automation, and source development must not become real users in
        # the production dashboard, even when exercising a packaged runtime.
        production = ENV["ALJAM3_BUNDLE_ROOT"] && !ENV["SCARPE_RUN_FILE"] &&
          !ENV["SCARPE_NATIVE_HEADLESS"] && !ENV["SCARPE_NATIVE_GHOST"] && !ENV["GITHUB_ACTIONS"]
        options = production ? {} : { environment: "development", transport: ->(_batch) { :sent } }
        @analytics = Analytics.new(directory:, **options)
        @analytics_subscriptions = [
          Shoes::DisplayService.subscribe_to_event("window_focus", linkable_id) do |focused, **|
            @analytics.focus(focused, reading: analytics_reading?)
          end,
          Shoes::DisplayService.subscribe_to_event("window_activity", linkable_id) do |focused, **|
            @analytics.activity(focused:, reading: analytics_reading?)
          end
        ]
      end

      def analytics_reading?
        return false unless @screen == :reader && @reader && !dialog_active? && !@library_moving && !@library_unavailable

        text = @reader[:mode] != :pdf && @reader[:page] && !@reader[:loading_text] && !@reader[:text_error]
        !!(text || (@reader[:mode] != :text && @reader[:image]))
      end

      def finish_analytics
        @analytics_subscriptions&.each { |subscription| Shoes::DisplayService.unsub_from_events(subscription) }
        @analytics&.close
      end
    end
  end
end
