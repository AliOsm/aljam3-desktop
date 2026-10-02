# frozen_string_literal: true

module Aljam3
  module UI
    module ReaderTools
      def reader_pane_widths
        return [width - 32, width - 32] unless @reader[:mode] == :split

        available = width - 48
        pdf = (available * @reader.fetch(:split_ratio)).round.clamp(240, available - 240)
        [pdf, available - pdf]
      end

      def draw_reader_divider
        @reader_divider = stack(left: @pdf_width + 16, top: @pane_top, width: 16, height: @pane_height) do
          line 8, 4, 8, @pane_height - 4, stroke: line_color
          image asset_path("icons", "grip-vertical"), top: @pane_height / 2 - 12, width: 16, height: 24,
            alt: "اسحب لتغيير مساحة النص والصورة. تتوفر النسب أيضًا في خيارات القراءة."
          click { @split_drag = true unless @dialog }
        end
      end

      def resize_reader_split(x)
        return unless @reader[:mode] == :split && @pdf_pane && @text_pane

        available = width - 48
        @reader[:split_ratio] = (x - 24).fdiv(available).clamp(0.25, 0.75)
        pdf, text = reader_pane_widths
        @pdf_width = pdf
        @pdf_pane.style(width: pdf)
        @text_pane.style(left: pdf + 32, width: text)
        @reader_divider.move(pdf + 16, @pane_top)
        draw_pdf_image
      end

      def bookmarked?
        @bookmarks.any? { |entry| entry["file_id"] == @reader.fetch(:file).fetch("id") && entry["number"] == @reader.fetch(:number) }
      end

      def toggle_reader_bookmark
        @store.toggle_bookmark(@reader.fetch(:book).fetch("id"), file_id: @reader.fetch(:file).fetch("id"),
          number: @reader.fetch(:number), excerpt: page_text.gsub(/\s+/, " ")[0, 180])
        @bookmarks = @store.bookmarks(@reader.fetch(:book).fetch("id"))
        draw_window
      end

      def draw_bookmarks
        para "مواضع محفوظة في هذا الكتاب، تبقى معك بعد إغلاق التطبيق.", size: 15, stroke: muted
        stack(top: 52, width: 1.0, height: @content_height - 52, scroll: true) do
          if @bookmarks.empty?
            para "لا توجد فواصل بعد. احفظ الصفحة من زر الفاصل أو Ctrl/⌘ D.", size: 16, stroke: muted
          end
          @bookmarks.each do |entry|
            stack(margin_bottom: 20, margin_right: 12) do
              file = @reader.fetch(:files).find { |candidate| candidate.fetch("id") == entry.fetch("file_id") }
              para "#{file&.fetch('name')} · صفحة #{entry.fetch('number')}", size: 16
              para entry.fetch("excerpt"), size: 14, stroke: muted, margin_top: 8
              action("فتح الصفحة", width: 126, margin_top: 10, state: file ? nil : "disabled") do
                close_dialog
                @reader[:file] = file
                turn_page(entry.fetch("number"))
              end
            end
          end
        end
      end

      def draw_reader_menu
        [ ["الفواصل المحفوظة", "bookmark", :bookmarks], ["تنزيل الكتاب وتصديره", "download", :export],
          ["مشاركة الصفحة", "share-2", :share], ["اختصارات لوحة المفاتيح", "keyboard", :shortcuts] ].each do |label, icon, type|
          action(label, icon:, width: 1.0, height: 48, margin_bottom: 8, variant: :ghost) { open_dialog(type, nested: true) }
        end
        action("حفظ صورة الصفحة", icon: "image-down", width: 1.0, height: 48, variant: :ghost,
          state: @reader[:image] ? nil : "disabled") { save_page_image }
      end

      def draw_reader_options
        para "حجم النص", size: 16
        flow(top: 38, width: 1.0, height: 36) do
          action("−", width: 44, size: 21) { change_text_size(-2); draw_window }
          para @reader.fetch(:text_size).to_s, width: 70, align: "center", margin_top: 8
          action("+", width: 44, size: 21) { change_text_size(2); draw_window }
        end
        action(@reader[:tashkeel] ? "إخفاء التشكيل" : "إظهار التشكيل", icon: @reader[:tashkeel] ? "filled-shaddah" : "dotted-shaddah", selected: @reader[:tashkeel],
          top: 92, width: 1.0) { toggle_tashkeel; draw_window }
        para "مساحة النص والصورة", top: 152, size: 16
        para "اسحب الفاصل بينهما، أو اختر نسبة مريحة.", top: 180, size: 14, stroke: muted
        flow(top: 216, width: 1.0, height: 36) do
          { 0.35 => "نص أوسع", 0.5 => "متساويان", 0.65 => "PDF أوسع" }.each do |ratio, label|
            action(label, width: (@main_width / 3).floor, selected: (@reader[:split_ratio] - ratio).abs < 0.02) do
              @reader[:split_ratio] = ratio
              save_reader_options
              draw_window
              render_pdf if reader_pdf?
            end
          end
        end
        para "تُحفظ اختياراتك تلقائيًا.", top: 278, size: 14, stroke: muted
      end

      def reader_keypress(key)
        case key
        when :left, :page_down then turn_page(@reader.fetch(:number) + 1)
        when :right, :page_up then turn_page(@reader.fetch(:number) - 1)
        when :home then turn_page(1)
        when :end then turn_page(@reader.fetch(:file).fetch("pages_count"))
        when :control_d, :alt_d then toggle_reader_bookmark
        when :control_j, :alt_j then @page_field.focus
        when :f3 then move_reader_match(1)
        when :shift_f3 then move_reader_match(-1)
        when "?" then open_dialog(:shortcuts)
        end
      end

      def draw_shortcuts
        { "Ctrl / ⌘ F" => "بحث في الكتاب", "Ctrl / ⌘ D" => "حفظ الفاصل أو إزالته", "Ctrl / ⌘ J" => "الانتقال إلى رقم صفحة",
          "← / Page Down" => "الصفحة التالية", "→ / Page Up" => "الصفحة السابقة", "Home / End" => "بداية الملف / نهايته",
          "F3 / Shift F3" => "التطابق التالي / السابق في الصفحة", "Escape" => "إغلاق النافذة أو تمييز البحث" }.each do |keys, label|
          flow(height: 38) do
            para keys, width: 210, align: "left", size: 14, stroke: muted
            para label, width: -210, size: 15
          end
        end
      end

      def reader_text_parts(content)
        ranges = Text.match_ranges(content, @reader.fetch(:query))
        @reader[:match_index] = @reader.fetch(:match_index, 0).clamp(0, [ranges.length - 1, 0].max)
        offset = 0
        parts = ranges.each_with_index.flat_map do |(start, length), index|
          selected = index == @reader[:match_index]
          before = content[offset...start]
          offset = start + length
          [before, span(content[start, length], fill: selected ? primary : accent, stroke: selected ? "#ffffff" : ink)]
        end
        parts << content[offset..]
      end

      def reader_match_bar(top)
        count = Text.match_ranges(page_text, @reader.fetch(:query)).length
        position = count.zero? ? 0 : @reader.fetch(:match_index, 0) + 1
        flow(left: 16, top:, width: width - 32, height: 36) do
          icon_button("x", "إزالة تمييز البحث") { clear_reader_matches }
          icon_button("arrow-right", "التطابق السابق · Shift F3", state: count.zero? ? "disabled" : nil) { move_reader_match(-1) }
          icon_button("arrow-left", "التطابق التالي · F3", state: count.zero? ? "disabled" : nil) { move_reader_match(1) }
          @match_label = para "#{position} / #{count} في الصفحة", width: 164, size: 14, stroke: muted, margin_top: 9, align: "center"
          para "البحث: #{@reader.fetch(:query)[0, 64]}", width: -280, size: 15, stroke: primary, margin_top: 8
        end
      end

      def move_reader_match(change)
        change_reader_mode(:split) if @reader[:mode] == :pdf
        return unless @page_text && !@reader[:loading_text]

        count = Text.match_ranges(page_text, @reader.fetch(:query)).length
        return if count.zero?

        @reader[:match_index] = (@reader.fetch(:match_index, 0) + change) % count
        @page_text.replace(*reader_text_parts(page_text))
        @match_label.text = "#{@reader[:match_index] + 1} / #{count} في الصفحة" if @match_label
        focus_reader_match
      end

      def focus_reader_match
        return unless @page_text && @text_surface

        match = Text.match_ranges(page_text, @reader.fetch(:query))[@reader.fetch(:match_index, 0)]
        return unless match

        @page_text.cursor = match.first
        @text_surface.scroll_top = [@page_text.cursor_top - 32, 0].max
        @page_text.cursor = nil
      end

      def clear_reader_matches
        return if @reader.fetch(:query).empty?

        @reader[:query] = ""
        draw_window
      end

      def draw_unavailable_book
        para Text.plain(@dialog.fetch(:book).fetch("title")), size: 18
        para "هذا الكتاب متاح عبر الإنترنت ولم يُنزّل على جهازك. افتح كتابًا محمّلًا الآن، أو أعد الاتصال لتنزيله.",
          size: 16, stroke: muted, margin_top: 16
        action("كتبي المحمّلة", top: @content_height - 48, width: 152, variant: :solid) { navigate(:saved) }
      end
    end
  end
end
