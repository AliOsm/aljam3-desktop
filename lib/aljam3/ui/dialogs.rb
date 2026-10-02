# frozen_string_literal: true

module Aljam3
  module UI
    module Dialogs
      def open_dialog(type, nested: false, **data)
        @editing_field = nil
        @dialog_scroll ||= { results: @results&.scroll_top || 0, text: @text_surface&.scroll_top || 0, pdf: @pdf_surface&.scroll_top || 0 }
        @dialog_stack ||= []
        @dialog_stack << @dialog if nested && @dialog
        @dialog_stack.clear unless nested
        return_focus = @dialog&.dig(:type) == :reader_menu ? @dialog[:return_focus] : @last_action_key
        @dialog = { type:, anchor: @last_action_rect, return_focus:, **data }
        draw_window
        (@dialog_first || @dialog_close)&.focus
      end

      def close_dialog
        closed = @dialog
        @editing_field = nil
        was_search = closed&.dig(:type) == :book_search
        @store.cancel_search if was_search
        @dialog = @dialog_stack&.pop
        @book_search[:busy] = false if was_search
        @dialog_scroll = nil if block_given? && !@dialog
        yield if block_given?
        draw_window
        @dialog_scroll = nil unless @dialog
        @action_views[closed[:return_focus]]&.focus if closed
      end

      def draw_dialog
        type = @dialog.fetch(:type)
        sheet = type == :filters
        popup = %i[volumes reader_options reader_menu].include?(type)
        menu = type == :reader_menu
        requested_width, requested_height = case type
          when :filters then [368, height - 60]
          when :volumes then [360, [@reader.fetch(:files).length * 44 + 96 + (@reader.fetch(:files).length > 6 ? 52 : 0), 440].min]
          when :share then [480, 280]
          when :export then [620, [@reader.fetch(:files).length * 64 + 220, 620].min]
          when :choices then [520, 440]
          when :reader_options then [384, 336]
          when :reader_menu then [304, 216]
          when :bookmarks then [640, 540]
          when :shortcuts then [540, 420]
          when :remove_download then [560, 340]
          when :unavailable then [520, 320]
          else [800, 640]
        end
        panel_width = [width - 32, requested_width].min
        panel_height = [height - (sheet ? 60 : 32), requested_height].min
        if sheet
          left, top = width - panel_width, 60
        elsif popup && (anchor = @dialog[:anchor])
          x, y, w, h = anchor
          left = (x + w - panel_width).clamp(16, width - panel_width - 16)
          top = y + h + 8
          top = y - panel_height - 8 if top + panel_height > height - 16
          top = top.clamp(16, height - panel_height - 16)
        else
          left, top = (width - panel_width) / 2, (height - panel_height) / 2
        end
        stack(left: 0, top: 0, width: width, height: height) do
          background rgb(0, 0, 0, popup ? 0.10 : 0.28)
          click do |_button, x, y|
            close_dialog unless (left..left + panel_width).cover?(x) && (top..top + panel_height).cover?(y)
          end
        end
        @drawing_dialog = true
        main_width, content_height = @main_width, @content_height
        padding, body_top = menu ? 8 : 20, menu ? 8 : 76
        @main_width, @content_height = panel_width - padding * 2, panel_height - body_top - padding
        @dialog_close = @dialog_first = nil
        @dialog_panel = stack(left:, top:, width: panel_width, height: panel_height) do
          background card_color, curve: sheet ? 0 : CARD_RADIUS
          border line_color, curve: sheet ? 0 : CARD_RADIUS
          unless menu
            title = @dialog.fetch(:title, { filters: "خيارات البحث", book_search: "بحث في الكتاب", volumes: "ملفات الكتاب",
              authors: "اختر المؤلف", choices: "اختر", share: "مشاركة الصفحة", export: "تنزيل الملفات",
              reader_options: "خيارات القراءة", bookmarks: "الفواصل المحفوظة", shortcuts: "اختصارات لوحة المفاتيح",
              remove_download: "إزالة النسخة المحمّلة", unavailable: "الكتاب غير محمّل" }.fetch(type, ""))
            row(left: 20, top: 16, width: panel_width - 40) do
              para title, width: -36, size: 20, font: HEADING_FONT
              @dialog_close = icon_button("x", "إغلاق") { close_dialog }
            end
            separator(left: 20, top: 64, width: panel_width - 40)
          end
          stack(left: padding, top: body_top, width: @main_width, height: @content_height) do
            case type
            when :filters then draw_filters
            when :choices, :volumes then draw_choices
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
        end
      ensure
        @drawing_dialog = false
        @main_width, @content_height = main_width, content_height
      end

      def open_filters
        open_dialog(:filters, filters: @filters.dup)
      end

      def draw_filters
        filters = @dialog.fetch(:filters)
        para @mode == :content || @screen == :saved ? "اجمع بين المكتبة والتصنيف والمؤلف لتحديد نطاق البحث." : "اختر المكتبة أو التصنيف أو المؤلف لتصفح العناوين.",
          size: 15, stroke: muted
        { library: "المكتبة", category: "التصنيف", author: "المؤلف" }.each_with_index do |(key, label), index|
          para label, top: 76 + index * 92, size: 15
          choices = case key
                    when :library then @libraries.map { |entity| [library_name(entity), entity.fetch("id")] }
                    when :category then @categories.map { |entity| [entity.fetch("name"), entity.fetch("id")] }
                    else @store.preference("authors", []).map { |entity| [Text.plain(entity.fetch("name")), entity.fetch("id")] }
                    end
          scoped_label = @scope_label if filters[key] && filters[key] == @filters[key]
          selected = choices.find { |_, id| id == filters[key] }&.first || scoped_label || "الجميع"
          action(selected, key: [:filter, key], tooltip: selected, icon: "chevron-down", top: 102 + index * 92, width: 1.0, height: 40, align: "right") do
            selection = ->(value) do
              filters.clear unless @mode == :content || @screen == :saved
              value ? filters[key] = value : filters.delete(key)
            end
            if key == :author
              open_dialog(:authors, nested: true, query: "", selection:)
              request_authors
            else
              open_dialog(:choices, nested: true, title: "اختر #{label}", query: "", choices: [["الجميع", nil], *choices], selection:)
            end
          end
        end
        action("مسح التصفية", top: 390, width: 1.0, variant: :ghost) { filters.clear; draw_window }
        action("تطبيق", top: @content_height - 48, width: 1.0, variant: :solid) do
          @filters = filters
          @scope_label = nil
          @dialog = @dialog_scroll = nil
          request_catalog
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
        top = searchable ? 56 : 0
        @choices = stack(top:, width: 1.0, height: @content_height - top, scroll: true, direction: "rtl")
        update_choices
      end

      def update_choices
        drawing = @drawing_dialog
        @drawing_dialog = true
        choices = @dialog.fetch(:choices).select { |label, _| Text.normalize(label).include?(Text.normalize(@dialog.fetch(:query, ""))) }
        @choices.clear do
          choices.each do |label, value|
            selected = @dialog[:type] == :volumes && value.fetch("id") == @reader.fetch(:file).fetch("id")
            control = action(label, tooltip: label, width: 1.0, height: 44, margin_left: 14, margin_bottom: 4, variant: :ghost, align: "right", selected:) do
              selection = @dialog.fetch(:selection)
              close_dialog { selection.call(value) }
            end
            @dialog_first ||= control
          end
          para "لا توجد خيارات مطابقة.", stroke: muted if choices.empty?
        end
      ensure
        @drawing_dialog = drawing
      end

      def request_authors(page: 1)
        dialog = @dialog
        dialog[:busy] = true
        draw_window
        @network_worker.submit(-> { @library.authors(query: dialog.fetch(:query), page:) }) do |result, error|
          next unless @dialog.equal?(dialog)

          dialog.merge!(busy: false, result:, error: error && error_message(error))
          refresh_window
        end
      end

      def draw_author_choices
        row(height: 40) do
          field = input(@dialog.fetch(:query), width: -82, tooltip: "اسم المؤلف", placeholder: "اسم المؤلف…") { |control| @dialog[:query] = control.text }
          field.finish = proc { request_authors }
          action("بحث", width: 82, margin_left: 12, height: 40, variant: :solid) { request_authors }
        end
        scroll_area(top: 56, height: @content_height - 56, scroll: true) do
          selection = @dialog.fetch(:selection)
          action("جميع المؤلفين", width: 1.0, align: "right") { close_dialog { selection.call(nil) } }
          if @dialog[:busy]
            para "جارٍ البحث…", stroke: muted, margin_top: 16
          elsif @dialog[:error]
            para @dialog[:error], stroke: muted, margin_top: 16
          elsif (result = @dialog[:result])
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
        input(url, top: 48, width: 1.0, state: "readonly", align: "left", tooltip: "رابط الصفحة")
        action("نسخ الرابط", icon: "copy", top: 108, right: 0, width: 132, variant: :solid) do
          self.clipboard = url
          @share_feedback.text = "تم نسخ الرابط"
        end
        @share_feedback = para "", top: 156, size: 14, stroke: muted
      end
    end
  end
end
