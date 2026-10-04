# frozen_string_literal: true

require_relative "../navigation_history"

module Aljam3
  module UI
    module Navigation
      LOCATION_FIELDS = %i[screen mode query filters scope_filters scope_label search_scope search_order
        result result_query source expanded search_pool_size search_signature].freeze
      READER_FIELDS = %i[book files file number zoom mode text_size tashkeel split_ratio query].freeze

      def current_location
        fields = LOCATION_FIELDS.to_h { |key| [key, instance_variable_get("@#{key}")] }
        %i[filters scope_filters expanded].each { |key| fields[key] = (fields[key] || {}).dup }
        fields.merge(reader: @screen == :reader ? @reader.slice(*READER_FIELDS) : nil,
          scroll: { results: @results&.scroll_top || 0, text: @text_surface&.scroll_top || 0, pdf: @pdf_surface&.scroll_top || 0 })
      end

      def remember_location
        return if !@screen || @screen == :opening

        (@history ||= NavigationHistory.new).visit(current_location)
        @pending_location_scroll = nil
      end

      def navigate_history(direction)
        if dialog_active?
          close_dialog if direction == :back
          return
        end
        location = @history&.move(direction, current_location)
        return unless location

        restore_location(location)
      end

      def restore_location(location)
        @store.cancel_search
        @request_number += 1
        @render_number += 1
        @page_request += 1
        @busy = false
        @catalog_refresh_pending = false
        @error = @dialog = @dialog_scroll = @results = @text_surface = @pdf_surface = nil
        @dialog_stack = []
        LOCATION_FIELDS.each { |key| instance_variable_set("@#{key}", location[key]) }
        %i[filters scope_filters expanded].each do |key|
          instance_variable_set("@#{key}", (location[key] || {}).dup)
        end
        @pending_location_scroll = location.fetch(:scroll).dup
        @navigation_motion = 0
        if @screen == :reader
          @reader = location.fetch(:reader).dup
          @bookmarks = @store.bookmarks(@reader.fetch(:book).fetch("id"))
          turn_page(@reader.fetch(:number), restoring: true)
        elsif !@result && (%i[browse saved authors].include?(@screen) || (@screen == :home && !@query.empty?))
          request_catalog
        else
          draw_window
        end
      end

      def restore_navigation_scroll
        return unless @pending_location_scroll

        { results: @results, text: @text_surface, pdf: @pdf_surface }.each do |key, surface|
          next unless surface && @pending_location_scroll.key?(key)
          next if key == :results && @busy
          next if key == :text && @reader[:loading_text]
          next if key == :pdf && !@reader[:image]

          surface.scroll_top = @pending_location_scroll.delete(key)
        end
      end
    end
  end
end
