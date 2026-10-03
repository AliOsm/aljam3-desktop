# frozen_string_literal: true

module Aljam3
  module UI
    module ReaderTools
      def reader_pane_widths
        available = width - PAGE_MARGIN * 2
        return [available, available] unless @reader[:mode] == :split

        available -= READER_GAP
        pdf = (available * @reader.fetch(:split_ratio)).round.clamp(240, available - 240)
        [pdf, available - pdf]
      end

      def draw_reader_divider
        @reader_divider = stack(left: PAGE_MARGIN + @pdf_width, top: @pane_top, width: READER_GAP, height: @pane_height) do
          line 8, 4, 8, @pane_height - 4, stroke: line_color
          image asset_path("icons", "grip-vertical"), top: @pane_height / 2 - 12, width: 16, height: 24,
            alt: "اسحب لتغيير مساحة النص والصورة. تتوفر النسب أيضًا في خيارات القراءة."
          click { @split_drag = true unless @dialog }
        end
      end

      def resize_reader_split(x)
        return unless @reader[:mode] == :split && @pdf_pane && @text_pane

        available = width - PAGE_MARGIN * 2 - READER_GAP
        @reader[:split_ratio] = (x - PAGE_MARGIN - READER_GAP / 2).fdiv(available).clamp(0.25, 0.75)
        pdf, text = reader_pane_widths
        @pdf_width = pdf
        @pdf_pane.style(width: pdf)
        @text_pane.style(left: PAGE_MARGIN + pdf + READER_GAP, width: text)
        @reader_divider.move(PAGE_MARGIN + pdf, @pane_top)
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
        scroll_area(top: 48, height: @content_height - 48, scroll: true) do
          if @bookmarks.empty?
            para "لا توجد فواصل بعد. احفظ الصفحة من زر الفاصل أو Ctrl/⌘ D.", size: 16, stroke: muted
          end
          @bookmarks.each do |entry|
            card(padding: 16) do
              file = @reader.fetch(:files).find { |candidate| candidate.fetch("id") == entry.fetch("file_id") }
              para "#{file&.fetch('name')} · صفحة #{entry.fetch('number')}", size: 16
              para entry.fetch("excerpt"), size: 14, stroke: muted, margin_top: 8
              row(margin_top: 12, height: 48) do
                action("فتح الصفحة", width: 126, state: file ? nil : "disabled") do
                  close_dialog
                  @reader[:file] = file
                  turn_page(entry.fetch("number"))
                end
              end
            end
          end
        end
      end

      def draw_reader_menu
        [ ["الفواصل المحفوظة", "bookmark", :bookmarks], ["تنزيل الكتاب وتصديره", "download", :export],
          ["مشاركة الصفحة", "share-2", :share], ["اختصارات لوحة المفاتيح", "keyboard", :shortcuts] ].each do |label, icon, type|
          control = action(label, icon:, width: 1.0, height: 40, margin_bottom: 4, variant: :ghost, align: "right") { open_dialog(type) }
          @dialog_first ||= control
        end
        action("حفظ صورة الصفحة", icon: "image-down", width: 1.0, height: 36, variant: :ghost, align: "right",
          state: @reader[:image] ? nil : "disabled") { save_page_image }
      end

      def draw_reader_options
        update_size = lambda do |change|
          change_text_size(change)
          @text_size_label.text = @reader.fetch(:text_size).to_s
          @text_larger.state = @reader[:text_size] >= 35 ? "disabled" : nil
          @text_smaller.state = @reader[:text_size] <= 17 ? "disabled" : nil
        end
        row do
          para "حجم النص", width: -140, size: 16
          @dialog_first = @text_larger = icon_button("plus", "تكبير النص", width: 44, variant: :outline, state: @reader[:text_size] >= 35 ? "disabled" : nil) { update_size.call(2) }
          @text_size_label = para @reader.fetch(:text_size).to_s, width: 52, align: "center"
          @text_smaller = icon_button("minus", "تصغير النص", width: 44, variant: :outline, state: @reader[:text_size] <= 17 ? "disabled" : nil) { update_size.call(-2) }
        end
        row(top: 48) do
          para "إظهار التشكيل", width: -96, size: 16
          state = para @reader[:tashkeel] ? "مفعّل" : "متوقف", width: 56, size: 13, stroke: muted, align: "center"
          @tashkeel_switch = check(checked: @reader[:tashkeel], variant: "switch", tooltip: "إظهار التشكيل",
            width: 40, height: 36, color: primary, background_color: line_color, direction: "rtl") do
            toggle_tashkeel
            state.text = @reader[:tashkeel] ? "مفعّل" : "متوقف"
          end
        end
        if @reader[:mode] == :split
          separator(top: 100)
          para "مساحة النص والصورة", top: 116, size: 16
          row(top: 148) do
            choices = { 0.35 => "نص أوسع", 0.5 => "متساويان", 0.65 => "صورة أوسع" }
            choices.each_with_index do |(ratio, label), index|
              gap = index < choices.length - 1 ? 8 : 0
              action(label, width: (@main_width - 16).fdiv(3) + gap, margin_right: gap, selected: (@reader[:split_ratio] - ratio).abs < 0.02) do
                @reader[:split_ratio] = ratio
                save_reader_options
                draw_window
                render_pdf
              end
            end
          end
        end
        para "تُحفظ اختياراتك تلقائيًا.", top: @reader[:mode] == :split ? 200 : 100, size: 13, stroke: muted
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
          row(height: 38) do
            para label, width: -200, size: 15
            para keys, width: 200, align: "left", size: 14, stroke: muted
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
        row(left: PAGE_MARGIN, top:, width: @main_width) do
          para "البحث: #{@reader.fetch(:query)[0, 64]}", width: -272, size: 15, stroke: primary, wrap: "trim"
          @match_label = para "#{position} / #{count} في الصفحة", width: 164, size: 14, stroke: muted, align: "center"
          icon_button("arrow-right", "التطابق السابق · Shift F3", state: count.zero? ? "disabled" : nil) { move_reader_match(-1) }
          icon_button("arrow-left", "التطابق التالي · F3", state: count.zero? ? "disabled" : nil) { move_reader_match(1) }
          icon_button("x", "إزالة تمييز البحث") { clear_reader_matches }
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
