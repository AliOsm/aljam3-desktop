# frozen_string_literal: true

module Aljam3
  module UI
    module Dialogs
      def open_dialog(type, nested: false, **data)
        @dialog_scroll ||= { results: @results&.scroll_top || 0, text: @text_surface&.scroll_top || 0, pdf: @pdf_surface&.scroll_top || 0 }
        @dialog_stack ||= []
        @dialog_stack << @dialog if nested && @dialog
        @dialog = { type:, **data }
        draw_window
      end

      def close_dialog
        was_search = @dialog&.dig(:type) == :book_search
        @dialog = @dialog_stack&.pop
        @book_search[:busy] = false if was_search
        draw_window
        @dialog_scroll = nil unless @dialog
      end

      def draw_dialog
        type = @dialog.fetch(:type)
        sheet = type == :filters
        requested_width, requested_height = case type
          when :filters then [368, height]
          when :volumes then [360, [@reader.fetch(:files).length * 48 + 160, 440].min]
          when :share then [520, 284]
          when :export then [660, [@reader.fetch(:files).length * 54 + 232, 620].min]
          when :choices then [560, 420]
          else [780, 620]
          end
        panel_width = [width - 32, requested_width].min
        panel_height = [sheet ? height : height - 64, requested_height].min
        left, top = if sheet
          [width - panel_width, 0]
        elsif type == :volumes
          [16, height - 72 - panel_height]
        else
          [(width - panel_width) / 2, (height - panel_height) / 2]
        end
        stack(left: 0, top: 0, width: width, height: height) do
          background rgb(0, 0, 0, type == :volumes ? 0 : 0.45)
          click do |_button, x, y|
            close_dialog unless (left..left + panel_width).cover?(x) && (top..top + panel_height).cover?(y)
          end
        end
        @drawing_dialog = true
        main_width, content_height = @main_width, @content_height
        @main_width, @content_height = panel_width - 32, panel_height - 86
        stack(left:, top:, width: panel_width, height: panel_height) do
          background card_color, curve: sheet ? 0 : CARD_RADIUS
          border line_color, curve: sheet ? 0 : CARD_RADIUS
          icon_button("x", "إغلاق", left: 12, top: 12) { close_dialog }
          title = @dialog.fetch(:title, { filters: "خيارات البحث", book_search: "بحث في الكتاب", volumes: "ملفات الكتاب",
            authors: "اختر المؤلف", choices: "اختر", share: "مشاركة الصفحة", export: "تنزيل الملفات" }.fetch(@dialog.fetch(:type)))
          para title, left: 56, top: 18, width: panel_width - 76, size: 21, font: HEADING_FONT
          line 16, 62, panel_width - 16, 62, stroke: line_color
          stack(left: 16, top: 74, width: @main_width, height: @content_height) do
            case @dialog.fetch(:type)
            when :filters then draw_filters
            when :choices, :volumes then draw_choices
            when :authors then draw_author_choices
            when :book_search then draw_book_search
            when :share then draw_share
            when :export then draw_export
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
          action(selected[0, 40], tooltip: selected, icon: "chevron-down", top: 102 + index * 92, width: 1.0, height: 40) do
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
        input(@dialog.fetch(:query, ""), width: 1.0, tooltip: "البحث في القائمة") do |field|
          @dialog[:query] = field.text
          update_choices
        end
        @choices = stack(top: 56, width: 1.0, height: @content_height - 56, scroll: true)
        update_choices
      end

      def update_choices
        drawing = @drawing_dialog
        @drawing_dialog = true
        choices = @dialog.fetch(:choices).select { |label, _| Text.normalize(label).include?(Text.normalize(@dialog.fetch(:query, ""))) }
        @choices.clear do
          choices.each do |label, value|
            action(label, width: 1.0, height: 44, margin_right: 12, margin_bottom: 4, variant: :ghost) do
              selection = @dialog.fetch(:selection)
              close_dialog
              selection.call(value)
              draw_window
            end
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
          draw_window
        end
      end

      def draw_author_choices
        flow(height: 40) do
          action("بحث", width: 70, margin_right: 12) { request_authors }
          field = input(@dialog.fetch(:query), width: -82, tooltip: "اسم المؤلف") { |control| @dialog[:query] = control.text }
          field.finish = proc { request_authors }
        end
        stack(top: 56, width: 1.0, height: @content_height - 56, scroll: true) do
          selection = @dialog.fetch(:selection)
          action("جميع المؤلفين", width: 1.0, margin_right: 12) { close_dialog; selection.call(nil); draw_window }
          if @dialog[:busy]
            para "جارٍ البحث…", stroke: muted, margin_top: 16
          elsif @dialog[:error]
            para @dialog[:error], stroke: muted, margin_top: 16
          elsif (result = @dialog[:result])
            result.data.fetch("authors").each do |author|
              action(Text.plain(author.fetch("name")), width: 1.0, height: 44, margin_right: 12, variant: :ghost) do
                close_dialog
                selection.call(author.fetch("id"))
                draw_window
              end
            end
            current, total = result.data.fetch("pagination").values_at("current_page", "total_pages")
            action("التالي", width: 100) { request_authors(page: current + 1) } if current < total
            action("السابق", width: 100) { request_authors(page: current - 1) } if current > 1
          end
        end
      end

      def draw_share
        para "رابط إلى الصفحة الحالية على الجامع.", size: 15, stroke: muted
        url = "https://aljam3.com/ar/#{@reader.fetch(:book).fetch('id')}/#{@reader.fetch(:file).fetch('id')}/#{@reader.fetch(:number)}"
        input(url, top: 48, width: 1.0, state: "readonly", align: "left", tooltip: "رابط الصفحة")
        action("نسخ الرابط", icon: "copy", top: 108, width: 132, variant: :solid) do
          self.clipboard = url
          @share_feedback.text = "تم نسخ الرابط"
        end
        @share_feedback = para "", top: 158, size: 14, stroke: muted
      end
    end
  end
end
