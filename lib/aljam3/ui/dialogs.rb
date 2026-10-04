# frozen_string_literal: true

module Aljam3
  module UI
    module Dialogs
      def dialog_active?
        @dialog || @closing_dialog
      end

      def open_dialog(type, nested: false, **data)
        @editing_field = nil
        @dialog[:scroll] = @dialog_results.scroll_top if @dialog && @dialog_results
        @dialog_stack ||= []
        @dialog_stack << @dialog if nested && @dialog
        @dialog_stack.clear unless nested
        return_focus = @dialog&.dig(:type) == :reader_menu ? @dialog[:return_focus] : @last_action_key
        return_control = @dialog&.dig(:return_control) || @last_content_focus
        anchor = nested && @dialog ? @dialog[:anchor] : @last_action_rect
        @dialog = { type:, anchor:, return_focus:, return_control:, **data }
        @closing_dialog = nil
        @dialog_redraw_pending = false
        @dialog_results = nil
        @content_layer.inert = true
        update_notification
        render_dialog(enter: !nested, direction: nested ? -8 : nil)
        (@dialog_first || @dialog_close)&.focus
      end

      def close_dialog
        return unless @dialog

        closed = @dialog
        @editing_field = nil
        if closed[:type] == :book_search
          @store.cancel_search
          @book_search[:busy] = false
        end
        @dialog = @dialog_stack&.pop
        @dialog_results = nil
        if @dialog
          yield if block_given?
          render_dialog(direction: 8)
          (@action_views[closed[:return_focus]] || @dialog_first || @dialog_close)&.focus
          return
        end
        @closing_dialog = closed
        yield if block_given?
        unless @closing_dialog.equal?(closed)
          @action_views[closed[:return_focus]]&.focus unless @dialog
          return
        end

        @motion.cancel(:dialog)
        @dialog_layer.inert = true
        @motion.to(@dialog_backdrop, opacity: 0.0, duration: 0.10, group: :dialog_shell)
        @motion.to(@dialog_panel, opacity: 0.0, displace_top: @dialog_offset,
          duration: 0.10, group: :dialog_shell, complete: -> { finish_dialog_close(closed) })
      end

      def finish_dialog_close(closed)
        return unless @closing_dialog.equal?(closed)

        clear_dialog_view
        @dialog_scroll = nil
        @content_layer.inert = false
        @action_views = @base_action_views.dup
        control = closed[:return_control]
        control = @action_views[closed[:return_focus]] unless control && Shoes::DisplayService.layout_cache.key?(control.linkable_id)
        control&.focus
        update_notification
      end

      def clear_dialog_view
        @motion.cancel(:dialog)
        @motion.cancel(:dialog_shell)
        @dialog_transition&.clear
        @dialog_layer.clear
        @dialog_layer.hidden = true
        @closing_dialog = @dialog_panel = @dialog_surface = @dialog_position = @dialog_results = nil
      end

      def render_dialog(enter: false, direction: nil)
        return unless @dialog

        @dialog_redraw_pending = false
        @dialog[:scroll] = @dialog_results.scroll_top if @dialog_results
        clear_dialog_view if enter
        @motion.cancel(:dialog)
        @action_views = @base_action_views.dup
        @dialog_results = nil
        @dialog_layer.style(hidden: false, inert: false)
        layout = dialog_layout
        @dialog_layer.append { draw_dialog_shell(layout) } unless @dialog_panel
        @dialog_panel.accessibility_label = layout.fetch(:title)
        @dialog_transition.replace(direction:) do |view|
          if view
            view.style(width: layout.fetch(:width), height: layout.fetch(:height))
            view.clear { draw_dialog_contents(layout) }
            view
          else
            content = nil
            @dialog_panel.append do
              content = stack(left: 0, top: 0, width: layout.fetch(:width), height: layout.fetch(:height)) { draw_dialog_contents(layout) }
            end
            content
          end
        end
        fit_dialog_panel
        return unless enter

        @dialog_backdrop.opacity = 0.0
        @dialog_panel.style(opacity: 0.0, displace_top: @dialog_offset)
        @motion.to(@dialog_backdrop, opacity: 1.0, duration: @dialog_duration, group: :dialog_shell)
        @motion.to(@dialog_panel, opacity: 1.0, displace_top: 0, duration: @dialog_duration, group: :dialog_shell)
      end

      def fit_dialog_panel
        return unless @dialog_panel

        heights = @dialog_transition.views.map { |view| view.style[:height] }
        @dialog_panel.height = heights.max
        # Keep the shared area opaque while the differently sized surfaces fade.
        @dialog_surface.height = heights.min
      end

      def refresh_dialog
        @editing_field ? @dialog_redraw_pending = true : render_dialog
      end

      def dialog_layout
        type = @dialog.fetch(:type)
        shell_type = @dialog_stack.first&.fetch(:type) || type
        popup = %i[select filters volumes reader_options reader_menu].include?(shell_type)
        menu = %i[select reader_menu].include?(type) && @dialog_stack.empty?
        requested_width, requested_height = case type
          when :motion_settings then [440, 160]
          when :filters then [408, 308]
          when :select then [220, (menu ? 12 : 80) + @dialog.fetch(:choices).length * 44]
          when :volumes then [360, choice_dialog_height]
          when :share then [480, 200]
          when :export then [520, [@reader.fetch(:files).length * 44 + 148, 544].min]
          when :choices then [@dialog_stack.any? ? 408 : 520, choice_dialog_height]
          when :authors then [480, author_dialog_height]
          when :book_search then [720, book_search_dialog_height]
          when :reader_options then [384, @reader[:mode] == :split ? 296 : 196]
          when :reader_menu then [304, 216]
          when :bookmarks then [600, @bookmarks.empty? ? 128 : [99 + @bookmarks.length * 76, 496].min]
          when :shortcuts then [540, 384]
          when :remove_download then [560, 296]
          when :unavailable then [520, 264]
          else [800, 640]
        end
        @dialog[:panel_width] = requested_width
        panel_width = [width - 32, @dialog_stack.first&.fetch(:panel_width, requested_width) || requested_width].min
        panel_height = [height - 32, requested_height].min
        anchor = @dialog[:anchor]
        if @dialog_position
          left, top, panel_width = @dialog_position
          panel_height = [panel_height, height - top - 16].min
        elsif popup && anchor
          x, y, w, h = anchor
          left = (x + w - panel_width).clamp(16, width - panel_width - 16)
          top = y + h + 8
          top = y - panel_height - 8 if top + panel_height > height - 16
          top = top.clamp(16, height - panel_height - 16)
        else
          left, top = (width - panel_width) / 2, (height - panel_height) / 2
        end
        @dialog_rest_top = top
        @dialog_offset = popup ? (anchor && top < anchor[1] ? 5 : -5) : 8
        @dialog_duration = popup ? 0.14 : 0.20
        title = @dialog.fetch(:title, { motion_settings: "إعدادات الحركة", filters: "خيارات البحث", book_search: "بحث في الكتاب", volumes: "ملفات الكتاب",
          authors: "اختر المؤلف", choices: "اختر", share: "مشاركة الصفحة", export: "تنزيل الملفات",
          reader_options: "خيارات القراءة", bookmarks: "الفواصل المحفوظة", shortcuts: "اختصارات لوحة المفاتيح",
          remove_download: "إزالة النسخة المحمّلة", unavailable: "الكتاب غير محمّل" }.fetch(type, "اختر"))
        backdrop_alpha = shell_type == :select ? 0 : popup ? 0.10 : 0.28
        { type:, menu:, left:, top:, width: panel_width, height: panel_height, title:, backdrop_alpha: }
      end

      def draw_dialog_shell(layout)
        left, top, panel_width, panel_height = layout.values_at(:left, :top, :width, :height)
        @dialog_position = [left, top, panel_width]
        stack(left: 0, top: 0, width: width, height: height) do
          @dialog_backdrop = background rgb(0, 0, 0, layout.fetch(:backdrop_alpha)), opacity: 1.0
          click do |_button, x, y|
            next unless @dialog

            bounds = Shoes::DisplayService.layout_cache[@dialog_panel.linkable_id]
            px, py, pw, ph = bounds || [left, top, panel_width, panel_height]
            close_dialog unless (px..px + pw).cover?(x) && (py..py + ph).cover?(y)
          end
        end
        @dialog_panel = stack(left:, top:, width: panel_width, height: panel_height, opacity: 1.0, displace_top: 0,
          accessibility_role: "dialog", accessibility_label: layout.fetch(:title)) do
          @dialog_surface = stack(left: 0, top: 0, width: panel_width, height: panel_height) { background card_color, curve: CARD_RADIUS }
        end
        @dialog_transition = ViewTransition.new(@motion, group: :dialog_content) { fit_dialog_panel }
      end

      def draw_dialog_contents(layout)
        @drawing_dialog = true
        main_width, content_height = @main_width, @content_height
        type, menu = layout.values_at(:type, :menu)
        padding, body_top = menu ? 8 : 16, menu ? 8 : 64
        @main_width, @content_height = layout.fetch(:width) - padding * 2, layout.fetch(:height) - body_top - padding
        @dialog_close = @dialog_first = nil
        background card_color, curve: CARD_RADIUS
        border line_color, curve: CARD_RADIUS
        unless menu
          row(left: padding, top: 12, width: @main_width) do
            para layout.fetch(:title), width: -36, size: 20, font: HEADING_FONT
            @dialog_close = if @dialog_stack.any?
              icon_button("arrow-right", "العودة", key: :dialog_back) { close_dialog }
            else
              icon_button("x", "إغلاق") { close_dialog }
            end
          end
          separator(left: padding, top: 56, width: @main_width)
        end
        stack(left: padding - SCROLL_GUTTER, top: body_top, width: @main_width + SCROLL_GUTTER,
          padding_left: SCROLL_GUTTER, height: @content_height) do
          case type
          when :motion_settings then draw_motion_settings
          when :filters then draw_filters
          when :select, :choices, :volumes then draw_choices
          when :authors then draw_author_choices
          when :book_search then draw_book_search
          when :share then draw_share
          when :export then draw_export
          when :reader_options then draw_reader_options
          when :reader_menu then draw_reader_menu
          when :bookmarks then draw_bookmarks
          when :shortcuts then draw_shortcuts
          when :remove_download then draw_remove_download
          when :unavailable then draw_unavailable_book
          end
        end
      ensure
        @drawing_dialog = false
        @main_width, @content_height = main_width, content_height
      end

      def open_filters
        open_dialog(:filters, filters: @filters.dup)
      end

      def choice_dialog_height
        count = @dialog.fetch(:choices).length
        [76 + [count, 1].max * 44 + (count > 6 ? 48 : 0), 432].min
      end

      def draw_filters
        filters = @dialog.fetch(:filters)
        para "يمكنك الجمع بين الخيارات لتحديد نطاق البحث.",
          size: 14, stroke: muted
        { library: "المكتبة", category: "التصنيف", author: "المؤلف" }.each_with_index do |(key, label), index|
          choices = case key
                    when :library then @libraries.map { |entity| [library_name(entity), entity.fetch("id")] }
                    when :category then @categories.map { |entity| [entity.fetch("name"), entity.fetch("id")] }
                    else []
                    end
          selected = filters[key] ? filter_label(key, filters[key]) : "الجميع"
          row(top: 32 + index * 48, height: 40) do
            para label, width: 76, size: 15
            action(selected, key: [:filter, key], tooltip: selected, icon: "chevron-down", width: -76, height: 40, align: "right",
              state: (@scope_filters || {}).key?(key) ? "disabled" : nil) do
              selection = ->(value) do
                value ? filters[key] = value : filters.delete(key)
              end
              if key == :author
                open_dialog(:authors, nested: true, query: "", selection:)
                request_authors
              else
                open_dialog(:choices, nested: true, title: "اختر #{label}", query: "", choices: [["الجميع", nil], *choices], selected: filters[key], selection:)
              end
            end
          end
        end
        separator(top: 180)
        row(top: 192) do
          action("مسح التصفية", width: 124, variant: :ghost) { filters.replace(@scope_filters || {}); render_dialog }
          stack(width: -228, height: 1)
          action("تطبيق", width: 104, variant: :solid) do
            @filters = filters.merge(@scope_filters || {})
            @dialog = @dialog_scroll = nil
            @screen = :browse if @screen == :home && @query.strip.empty?
            request_catalog
          end
        end
      end

      def draw_choices
        searchable = @dialog.fetch(:choices).size > 6
        if searchable
          @dialog_first = input(@dialog.fetch(:query, ""), width: 1.0, tooltip: "البحث في القائمة", placeholder: "ابحث في القائمة…") do |field|
            @dialog[:query] = field.text
            update_choices
          end
        end
        top = searchable ? 48 : 0
        scroll_area(top:, height: @content_height - top, scroll: true, bottom_padding: 0) { @choices = stack }
        update_choices
      end

      def update_choices
        drawing = @drawing_dialog
        @drawing_dialog = true
        choices = @dialog.fetch(:choices).select { |label, _| Text.normalize(label).include?(Text.normalize(@dialog.fetch(:query, ""))) }
        @choices.clear do
          choices.each_with_index do |(label, value), index|
            selected = if @dialog[:type] == :volumes
              value.fetch("id") == @reader.fetch(:file).fetch("id")
            else
              @dialog.key?(:selected) && value == @dialog[:selected]
            end
            gap = index < choices.length - 1 ? 4 : 0
            control = action(label, tooltip: label, width: 1.0, height: 40 + gap, margin_bottom: gap, variant: :ghost, align: "right", selected:) do
              selection = @dialog.fetch(:selection)
              close_dialog { selection.call(value) }
            end
            @dialog_first = control if !@dialog_first || (selected && @dialog[:type] == :select)
          end
          para "لا توجد خيارات مطابقة.", stroke: muted if choices.empty?
        end
      ensure
        @drawing_dialog = drawing
      end

      def request_authors(page: 1)
        dialog = @dialog
        dialog[:busy] = true
        render_dialog
        @network_worker.submit(-> { @library.authors(query: dialog.fetch(:query), page:) }) do |result, error|
          next unless @dialog.equal?(dialog)

          dialog.merge!(busy: false, result:, error: error && error_message(error))
          refresh_dialog
        end
      end

      def author_dialog_height
        result = @dialog[:result] unless @dialog[:busy] || @dialog[:error]
        return 196 unless result && result.data.fetch("authors").any?

        pagination = result.data.fetch("pagination")
        footer = pagination.fetch("total_pages") > 1 ? 52 : 0
        [172 + result.data.fetch("authors").length * 44 + footer, 432].min
      end

      def draw_author_choices
        row(height: 40) do
          @dialog_first = field = input(@dialog.fetch(:query), width: -82, tooltip: "اسم المؤلف", placeholder: "اسم المؤلف…") { |control| @dialog[:query] = control.text }
          field.finish = proc { request_authors }
          action("بحث", width: 82, margin_left: 12, height: 40, variant: :solid) { request_authors }
        end
        scroll_area(top: 48, height: @content_height - 48, scroll: true, bottom_padding: 0) do
          selection = @dialog.fetch(:selection)
          action("جميع المؤلفين", width: 1.0, margin_bottom: 8, align: "right") { close_dialog { selection.call(nil) } }
          if @dialog[:busy]
            para "جارٍ البحث…", size: 15, stroke: muted, margin_top: 4
          elsif @dialog[:error]
            para @dialog[:error], size: 15, stroke: muted, margin_top: 4
          elsif (result = @dialog[:result])
            para "لا توجد أسماء مطابقة.", size: 15, stroke: muted, margin_top: 4 if result.data.fetch("authors").empty?
            result.data.fetch("authors").each do |author|
              action(Text.plain(author.fetch("name"))[0, 72], width: 1.0, height: 44, variant: :ghost, align: "right") do
                close_dialog { selection.call(author.fetch("id")) }
              end
            end
            current, total = result.data.fetch("pagination").values_at("current_page", "total_pages")
            page_controls(page: current, previous: current > 1, following: current < total) { |number| request_authors(page: number) }
          end
        end
      end

      def draw_share
        para "رابط إلى الصفحة الحالية على الجامع.", size: 15, stroke: muted
        url = "https://aljam3.com/ar/#{@reader.fetch(:book).fetch('id')}/#{@reader.fetch(:file).fetch('id')}/#{@reader.fetch(:number)}"
        input(url, top: 32, width: 1.0, state: "readonly", align: "left", tooltip: "رابط الصفحة")
        action("نسخ الرابط", icon: "copy", top: 84, right: 0, width: 132, variant: :solid, live: "polite") do |control|
          copy_with_feedback(url, control:, label: "نسخ الرابط")
        end
      end
    end
  end
end
