# frozen_string_literal: true

module Aljam3
  module UI
    module Reader
      def open_book(book, page_id: nil)
        files = @store.files(book.fetch("id"))
        return if files.empty?

        unless %i[reader book_search].include?(@screen)
          @catalog_return = { screen: @screen, scroll: @results&.scroll_top || 0 }
        end
        saved = @store.preference("reading:#{book.fetch('id')}", {})
        location = page_id ? @store.find_page(page_id) : saved
        file = files.find { |candidate| candidate.fetch("id") == location&.fetch("file_id", nil) }
        notice = "لم نجد صفحة النتيجة في النسخة المحمّلة. فُتحت بداية الكتاب." if page_id && !file
        options = @store.preference("reader", {})
        @reader = { book:, files:, file: file || files.first, zoom: 1.0,
          mode: options.fetch("mode", "split").to_sym, text_size: options.fetch("text_size", 20),
          tashkeel: options.fetch("tashkeel", true) }
        @screen = :reader
        @request_number += 1
        turn_page(file ? location.fetch("number", 1) : 1, notice:)
      end

      def close_reader
        @screen = @catalog_return.fetch(:screen)
        @render_number += 1
        draw_window
        @results.scroll_top = @catalog_return.fetch(:scroll) if @results && %i[browse saved].include?(@screen)
      end

      def save_reader_options
        @store.save_preference("reader", @reader.slice(:mode, :text_size, :tashkeel))
      end

      def draw_reader
        @pdf_surface = @page_image = @copy_button = @drag = nil
        book = @reader.fetch(:book)
        heading_height = width < 960 ? 60 : 38
        toolbar_top = heading_height + 82
        line 0, 1, width, 1, stroke: PRIMARY, strokewidth: 3
        action("رجوع", icon: "arrow-right", variant: :ghost, left: 24, top: 13, width: 88) { close_reader }
        para [book.dig("library", "name"), book.dig("category", "name")].compact.join("  /  "),
          left: 128, top: 22, width: width - 152, size: 13, stroke: MUTED
        para Text.plain(book.fetch("title")), left: 24, top: 53, width: width - 48,
          font: HEADING_FONT, size: width < 960 ? 20 : 24
        para Text.plain(book.dig("author", "name")), left: 24, top: heading_height + 55,
          width: width - 48, size: 14, stroke: MUTED
        action("بحث في الكتاب", icon: "search", left: 24, top: toolbar_top, width: 144) { open_book_search }
        tabs({ text: "النص", pdf: "PDF", split: "جنبًا إلى جنب" }, selected: @reader[:mode],
          left: (width - 312) / 2, top: toolbar_top, width: 312) { |mode| change_reader_mode(mode) }
        status_note("محفوظ على جهازك", left: width - 168, top: toolbar_top + 5, width: 144)
        pane_top = toolbar_top + 54
        if @reader[:notice]
          para @reader[:notice], left: 24, top: pane_top, width: width - 48, size: 15, stroke: PRIMARY
          pane_top += 34
        end
        pane_width = @reader[:mode] == :split ? (width - 64) / 2 : width - 48
        pane_height = height - pane_top - 80
        reader_text_pane(width: pane_width, height: pane_height, top: pane_top) unless @reader[:mode] == :pdf
        reader_pdf_pane(width: pane_width, height: pane_height, top: pane_top) if reader_pdf?
        reader_pagination
      end

      def page_text
        text = @store.page(@reader.fetch(:file).fetch("id"), @reader.fetch(:number))&.fetch("content").to_s.gsub(/\r\n?/, "\n")
        @reader.fetch(:tashkeel) ? text : Text.without_tashkeel(text)
      end

      def reader_text_pane(width:, height:, top:)
        stack(left: 24, top:, width:, height:) do
          background PAPER, curve: CARD_RADIUS
          border LINE, curve: CARD_RADIUS
          flow(left: 8, top: 7, width: width - 16, height: 36) do
            @copy_button = icon_button("copy", "نسخ نص الصفحة", state: page_text.strip.empty? ? "disabled" : nil) { copy_page }
            @tashkeel_button = action("تشكيل", width: 62, variant: :ghost, selected: @reader[:tashkeel], tooltip: "إظهار أو إخفاء التشكيل") { toggle_tashkeel }
            action("−", width: 36, variant: :ghost, size: 22, tooltip: "تصغير النص") { change_text_size(-2) }
            action("+", width: 36, variant: :ghost, size: 22, tooltip: "تكبير النص") { change_text_size(2) }
            para "نص الكتاب", width: -178, size: 16, margin_top: 8
          end
          line 1, 49, width - 1, 49, stroke: LINE
          @text_surface = stack(top: 50, width: 1.0, height: height - 51, scroll: true) do
            stack(margin: 24) do
              @page_text = para page_text.strip.empty? ? "لا يتوفر نص لهذه الصفحة." : page_text,
                font: READING_FONT, size: @reader.fetch(:text_size), leading: 8
            end
          end
        end
      end

      def copy_page
        self.clipboard = page_text
        control = @copy_button
        control.style(icon: File.join(ROOT, "assets/icons/check.png"), tooltip: "تم النسخ")
        timer(2) do
          control.style(icon: File.join(ROOT, "assets/icons/copy.png"), tooltip: "نسخ نص الصفحة") if control == @copy_button && @screen == :reader
        end
      end

      def change_text_size(change)
        @reader[:text_size] = (@reader.fetch(:text_size) + change).clamp(17, 35)
        @page_text.style(size: @reader.fetch(:text_size))
        save_reader_options
      end

      def toggle_tashkeel
        @reader[:tashkeel] = !@reader.fetch(:tashkeel)
        @page_text.text = page_text.strip.empty? ? "لا يتوفر نص لهذه الصفحة." : page_text
        @tashkeel_button.style(color: @reader[:tashkeel] ? ACCENT : "transparent")
        save_reader_options
      end

      def reader_pdf_pane(width:, height:, top:)
        @pdf_width, @pdf_height = width, height - 51
        stack(left: @reader[:mode] == :split ? width + 40 : 24, top:, width:, height:) do
          background PAPER, curve: CARD_RADIUS
          border LINE, curve: CARD_RADIUS
          flow(left: 8, top: 7, width: width - 16, height: 36) do
            icon_button("maximize", "ملاءمة الصفحة") { change_zoom(1.0 - @reader.fetch(:zoom)) }
            icon_button("zoom-out", "تصغير PDF") { change_zoom(-0.25) }
            icon_button("zoom-in", "تكبير PDF") { change_zoom(0.25) }
            @zoom_label = para "#{(@reader.fetch(:zoom) * 100).to_i}%", width: 52, size: 13, stroke: MUTED, align: "center", margin_top: 10
            para "الكتاب المصوّر", width: -168, size: 16, margin_top: 8
          end
          line 1, 49, width - 1, 49, stroke: LINE
          @pdf_surface = stack(top: 50, width: 1.0, height: @pdf_height, scroll: true) do
            background SURFACE
            para "جارٍ عرض الصفحة…", margin: 24, stroke: MUTED
          end
        end
      end

      def reader_pdf? = @screen == :reader && %i[pdf split].include?(@reader.fetch(:mode))

      def change_reader_mode(mode)
        return if @reader[:mode] == mode

        @reader[:mode] = mode
        save_reader_options
        draw_window
        render_pdf if reader_pdf?
      end

      def reader_pagination
        number = @reader.fetch(:number)
        count = @reader.fetch(:file).fetch("pages_count")
        line 24, height - 64, width - 24, height - 64, stroke: LINE
        flow(left: (width - 350) / 2, top: height - 52, width: 350, height: 38) do
          icon_button("chevrons-left", "آخر صفحة", state: number >= count ? "disabled" : nil) { turn_page(count) }
          icon_button("arrow-left", "الصفحة التالية", state: number >= count ? "disabled" : nil) { turn_page(number + 1) }
          action("انتقل", width: 56, variant: :ghost) { go_to_page }
          para "صفحة", width: 50, size: 14, stroke: MUTED, margin_top: 9
          @page_field = edit_line(number.to_s, width: 92, height: 36, margin_left: 8, margin_right: 12, align: "center", tooltip: "رقم الصفحة")
          @page_field.finish = proc { go_to_page }
          icon_button("arrow-right", "الصفحة السابقة", state: number <= 1 ? "disabled" : nil) { turn_page(number - 1) }
          icon_button("chevrons-right", "أول صفحة", state: number <= 1 ? "disabled" : nil) { turn_page(1) }
        end
        para "#{number} من #{count} صفحة", left: width - 194, top: height - 42, width: 170, size: 14, stroke: MUTED
        files = @reader.fetch(:files)
        action("الجزء #{files.index(@reader.fetch(:file)) + 1} / #{files.length}", icon: "chevron-down",
          left: 24, top: height - 52, width: 128, variant: :ghost, state: files.length == 1 ? "disabled" : nil) do
          choices = files.each_with_index.map { |file, index| ["الجزء #{index + 1} · #{file.fetch('pages_count')} صفحة", file] }
          open_picker("اختر المجلد", choices) { |file| @reader[:file] = file; turn_page(1) }
        end
      end

      def go_to_page
        number = Integer(@page_field.text.tr("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789"), exception: false)
        if number
          turn_page(number)
        else
          @page_field.text = @reader.fetch(:number).to_s
        end
      end

      def turn_page(number, notice: nil)
        @reader[:number] = number.clamp(1, @reader.fetch(:file).fetch("pages_count"))
        @reader[:notice] = notice
        @store.save_preference("reading:#{@reader.fetch(:book).fetch('id')}", { "file_id" => @reader.fetch(:file).fetch("id"), "number" => @reader.fetch(:number) })
        draw_window
        render_pdf if reader_pdf?
      end

      def change_zoom(change)
        @reader[:zoom] = (@reader.fetch(:zoom) + change).clamp(0.5, 3.0)
        @zoom_label.text = "#{(@reader.fetch(:zoom) * 100).to_i}%" if @zoom_label
        render_pdf if reader_pdf?
      end

      def render_pdf
        @render_number += 1
        render_number = @render_number
        path = @downloader.pdf_path(@reader.fetch(:book).fetch("id"), @reader.fetch(:file).fetch("id"))
        number, zoom = @reader.values_at(:number, :zoom)
        pane_width, pane_height = @pdf_width, @pdf_height
        @render_worker.submit(-> { @pdf.render(path, page: number, width: (pane_width - 32) * zoom * 1.5) }) do |rendered, error|
          next unless reader_pdf? && @render_number == render_number

          @pdf_surface.clear do
            background SURFACE
            if error
              para error_message(error), margin: 24
            else
              scale = [(pane_width - 32).fdiv(rendered.width), (pane_height - 32).fdiv(rendered.height)].min * zoom
              display_width, display_height = [(rendered.width * scale).round, (rendered.height * scale).round]
              @pan = (pane_width - display_width) / 2
              image_top = [(pane_height - display_height) / 2, 16].max
              stack(height: [display_height + 32, pane_height].max) do
                @page_image = image(rendered.path, width: display_width, left: @pan, top: image_top, alt: "صفحة #{number} من الكتاب")
                click { |_button, x, _y| @drag = [x, @pan] }
                motion do |x, _y|
                  next unless @drag && display_width > pane_width

                  @pan = (@drag[1] + x - @drag[0]).clamp(pane_width - display_width, 0).round
                  @page_image.move(@pan, image_top)
                end
                release { @drag = nil }
              end
            end
          end
        end
      end
    end
  end
end
