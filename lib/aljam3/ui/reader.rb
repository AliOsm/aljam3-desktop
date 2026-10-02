# frozen_string_literal: true

module Aljam3
  module UI
    module Reader
      def open_book(book, page_id: nil, hit: nil)
        unless @screen == :reader
          @catalog_return = { screen: @screen, scroll: @results&.scroll_top || 0 }
        end
        @dialog = @results = @dialog_scroll = nil
        @dialog_stack = []
        @request_number += 1
        if @store.downloaded?(book.fetch("id"))
          location = hit || (page_id && @store.find_page(page_id))
          location = @store.find_page(location.fetch("id")) if location && !location["file_id"]
          notice = "لم نجد صفحة النتيجة في النسخة المحمّلة. فُتحت بداية الكتاب." if (hit || page_id) && !location
          start_reader(book.merge("files" => @store.files(book.fetch("id"))), location:, notice:)
        else
          request_number = @request_number
          @screen = :opening
          draw_window
          @network_worker.submit(-> {
            full_book = @reading.book(book.fetch("id"))
            [full_book, hit && @reading.locate(full_book, hit)]
          }) do |data, error|
            next unless @request_number == request_number && @screen == :opening

            if error
              @screen = @catalog_return.fetch(:screen)
              @error = error_message(error)
              @busy = false
              draw_window
            else
              start_reader(data.first, location: data.last)
            end
          end
        end
      end

      def start_reader(book, location: nil, notice: nil)
        files = book.fetch("files")
        raise ResponseError.new(404), "This book has no files." if files.empty?

        saved = @store.preference("reading:#{book.fetch('id')}", {})
        location ||= saved
        file = files.find { |candidate| candidate.fetch("id") == location["file_id"] }
        options = @store.preference("reader", {})
        @reader = { book:, files:, file: file || files.first, zoom: 1.0,
          mode: options.fetch("mode", "split").to_sym, text_size: options.fetch("text_size", 20),
          tashkeel: options.fetch("tashkeel", true) }
        @screen = :reader
        turn_page(file ? location.fetch("number", 1) : 1, notice:)
      end

      def close_reader
        @page_request = (@page_request || 0) + 1
        @render_number = (@render_number || 0) + 1
        @screen = @catalog_return.fetch(:screen)
        draw_window
        @results.scroll_top = @catalog_return.fetch(:scroll) if @results
      end

      def save_reader_options
        @store.save_preference("reader", @reader.slice(:mode, :text_size, :tashkeel))
      end

      def draw_reader
        @pdf_surface = @text_surface = @page_image = @copy_button = @page_text = @drag = nil
        book = @reader.fetch(:book)
        heading_height = width < 960 ? 70 : 44
        toolbar_top = heading_height + 78
        line 0, 1, width, 1, stroke: primary, strokewidth: 3
        action("رجوع", icon: "arrow-right", variant: :ghost, left: 16, top: 12, width: 84) { close_reader }
        icon_button(@theme == :dark ? "sun" : "moon", "تغيير المظهر", left: 104, top: 12) { toggle_theme }
        category = book["category"]
        breadcrumb = [book["library"] && library_name(book.fetch("library")), category&.fetch("name")].compact.join("  /  ")
        para text_link(breadcrumb, stroke: muted) { browse_scope(:category, category) if category },
          left: 152, top: 22, width: width - 172, size: 13
        para Text.plain(book.fetch("title")), left: 16, top: 52, width: width - 32,
          size: width < 960 ? 23 : 27, weight: "semibold"
        author = book["author"]
        para text_link(Text.plain(author&.fetch("name")), stroke: muted) { browse_scope(:author, author) if author },
          left: 16, top: heading_height + 52, width: width - 32, size: 14
        reader_toolbar(toolbar_top)
        pane_top = toolbar_top + 68
        if @reader[:notice]
          para @reader[:notice], left: 16, top: pane_top, width: width - 32, size: 14, stroke: primary
          pane_top += 32
        end
        pane_width = @reader[:mode] == :split ? (width - 48) / 2 : width - 32
        pane_height = height - pane_top - 80
        reader_pdf_pane(width: pane_width, height: pane_height, top: pane_top) if reader_pdf?
        reader_text_pane(width: pane_width, height: pane_height, top: pane_top) unless @reader[:mode] == :pdf
        reader_pagination
      end

      def reader_toolbar(top)
        stack(left: 16, top:, width: width - 32, height: 52) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          if width >= 1040
            para "الكتاب المصوّر", left: 12, top: 19, width: 105, size: 14, align: "left"
            para "نص الكتاب", left: width - 150, top: 19, width: 100, size: 14
          end
          flow(left: (width - 32 - 590) / 2, top: 8, width: 590, height: 36) do
            icon_button("share-2", "مشاركة الصفحة") { open_dialog(:share) }
            icon_button("download", "تنزيل الملفات") { open_dialog(:export) }
            icon_button("image-down", "حفظ صورة الصفحة", state: @reader[:image] ? nil : "disabled") { save_page_image }
            icon_button("maximize", "ملاءمة الصفحة") { change_zoom(1.0 - @reader.fetch(:zoom)) }
            icon_button("zoom-out", "تصغير PDF") { change_zoom(-0.25) }
            icon_button("zoom-in", "تكبير PDF") { change_zoom(0.25) }
            flow(width: 132, height: 36, margin_left: 12, margin_right: 12) do
              { pdf: ["panel-left", "PDF فقط"], split: ["columns-2", "النص والصورة"], text: ["panel-right", "النص فقط"] }.each do |mode, (icon, label)|
                icon_button(icon, label, selected: @reader[:mode] == mode, variant: :outline) { change_reader_mode(mode) }
              end
            end
            @tashkeel_button = action("تشكيل", width: 58, variant: :ghost, selected: @reader[:tashkeel], tooltip: "إظهار أو إخفاء التشكيل") { toggle_tashkeel }
            action("−", width: 36, variant: :ghost, size: 21, tooltip: "تصغير النص") { change_text_size(-2) }
            action("+", width: 36, variant: :ghost, size: 21, tooltip: "تكبير النص") { change_text_size(2) }
            @copy_button = icon_button("copy", "نسخ نص الصفحة", state: page_text.strip.empty? ? "disabled" : nil) { copy_page }
            icon_button("search", "بحث في الكتاب") { open_book_search }
          end
        end
      end

      def page_text
        page = @reader[:page] || (@store.downloaded?(@reader.fetch(:book).fetch("id")) && @store.page(@reader.fetch(:file).fetch("id"), @reader.fetch(:number)))
        text = Text.plain(page ? page.fetch("content") : "").gsub(/\r\n?/, "\n")
        @reader.fetch(:tashkeel) ? text : Text.without_tashkeel(text)
      end

      def reader_text_pane(width:, height:, top:)
        left = @reader[:mode] == :split ? width + 32 : 16
        stack(left:, top:, width:, height:) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          @text_surface = stack(width: 1.0, height:, scroll: !@dialog) do
            stack(margin: 20) do
              if @reader[:text_error]
                para @reader[:text_error], size: 15, stroke: muted
                action("إعادة تحميل النص", margin_top: 16) { turn_page(@reader.fetch(:number)) }
              else
                content = @reader[:loading_text] ? "جارٍ تحميل النص…" : (page_text.strip.empty? ? "لا يتوفر نص لهذه الصفحة." : page_text)
                @page_text = para content, font: READING_FONT, size: @reader.fetch(:text_size), leading: 8
              end
            end
          end
        end
      end

      def copy_page
        self.clipboard = page_text
        control = @copy_button
        control.style(icon: asset_path("icons", "check"), tooltip: "تم النسخ")
        timer(2) do
          control.style(icon: asset_path("icons", "copy"), tooltip: "نسخ نص الصفحة") if control == @copy_button && @screen == :reader
        end
      end

      def change_text_size(change)
        @reader[:text_size] = (@reader.fetch(:text_size) + change).clamp(17, 35)
        @page_text&.style(size: @reader.fetch(:text_size))
        save_reader_options
      end

      def toggle_tashkeel
        @reader[:tashkeel] = !@reader.fetch(:tashkeel)
        @page_text.text = page_text if @page_text && !@reader[:loading_text] && !@reader[:text_error]
        @tashkeel_button.style(color: @reader[:tashkeel] ? accent : "transparent")
        save_reader_options
      end

      def reader_pdf_pane(width:, height:, top:)
        @pdf_width, @pdf_height = width, height
        stack(left: 16, top:, width:, height:) do
          background surface, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          @pdf_surface = stack(width: 1.0, height:, scroll: !@dialog)
        end
        draw_pdf_image
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
        number, file = @reader.values_at(:number, :file)
        count = file.fetch("pages_count")
        stack(left: 16, top: height - 64, width: width - 32, height: 48) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
        end
        flow(left: (width - 338) / 2, top: height - 58, width: 338, height: 36) do
          icon_button("chevrons-left", "آخر صفحة", state: number >= count ? "disabled" : nil) { turn_page(count) }
          icon_button("arrow-left", "الصفحة التالية", state: number >= count ? "disabled" : nil) { turn_page(number + 1) }
          action("انتقل", width: 52, variant: :ghost) { go_to_page }
          @page_field = input(number.to_s, width: 94, height: 36, margin_left: 8, margin_right: 12, align: "center", tooltip: "رقم الصفحة")
          @page_field.finish = proc { go_to_page }
          icon_button("arrow-right", "الصفحة السابقة", state: number <= 1 ? "disabled" : nil) { turn_page(number - 1) }
          icon_button("chevrons-right", "أول صفحة", state: number <= 1 ? "disabled" : nil) { turn_page(1) }
        end
        para "#{number} / #{count}", left: width - 150, top: height - 46, width: 110, size: 14, stroke: muted
        files = @reader.fetch(:files)
        action("ملفات الكتاب", icon: "chevron-down", left: 26, top: height - 58, width: 130, variant: :ghost) do
          choices = files.map { |item| ["#{item.fetch('name')} · #{item.fetch('pages_count')} صفحة", item] }
          open_dialog(:volumes, query: "", choices:, selection: ->(selected) { @reader[:file] = selected; turn_page(1) })
        end
      end

      def go_to_page
        number = Integer(@page_field.text.tr("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789"), exception: false)
        number ? turn_page(number) : @page_field.text = @reader.fetch(:number).to_s
      end

      def turn_page(number, notice: nil)
        @text_surface = @pdf_surface = nil
        file, book = @reader.values_at(:file, :book)
        number = number.clamp(1, file.fetch("pages_count"))
        @reader.merge!(number:, notice:, image: nil, pdf_error: nil, page: nil, text_error: nil)
        @page_request = (@page_request || 0) + 1
        request_number = @page_request
        @store.save_preference("reading:#{book.fetch('id')}", { "file_id" => file.fetch("id"), "number" => number })
        if @store.downloaded?(book.fetch("id"))
          @reader[:page] = @store.page(file.fetch("id"), number)
          @reader[:loading_text] = false
        else
          @reader[:loading_text] = true
          @page_worker.submit(-> { @reading.page(book.fetch("id"), file.fetch("id"), number) }) do |page, error|
            next unless @screen == :reader && @page_request == request_number

            @reader.merge!(page:, loading_text: false, text_error: error && error_message(error))
            draw_window
          end
        end
        draw_window
        render_pdf if reader_pdf?
      end

      def change_zoom(change)
        @reader[:zoom] = (@reader.fetch(:zoom) + change).clamp(0.5, 3.0)
        render_pdf if reader_pdf?
      end

      def render_pdf
        @render_number = (@render_number || 0) + 1
        render_number = @render_number
        book, file, number, zoom = @reader.values_at(:book, :file, :number, :zoom)
        pane_width = @pdf_width
        @render_worker.submit(-> {
          path = @reading.pdf_path(book.fetch("id"), file)
          @pdf.render(path, page: number, width: (pane_width - 32) * zoom * 1.5)
        }) do |rendered, error|
          next unless @screen == :reader && @render_number == render_number

          @reader.merge!(image: rendered, pdf_error: error && error_message(error))
          draw_window
        end
      end

      def draw_pdf_image
        return unless @pdf_surface

        @pdf_surface.clear do
          if @reader[:pdf_error]
            para @reader[:pdf_error], margin: 24, size: 15, stroke: muted
            action("إعادة تحميل PDF", margin: 24) { render_pdf }
          elsif (rendered = @reader[:image])
            scale = [(@pdf_width - 32).fdiv(rendered.width), (@pdf_height - 32).fdiv(rendered.height)].min * @reader.fetch(:zoom)
            display_width, display_height = [(rendered.width * scale).round, (rendered.height * scale).round]
            @pan = (@pdf_width - display_width) / 2
            image_top = [(@pdf_height - display_height) / 2, 16].max
            stack(height: [display_height + 32, @pdf_height].max) do
              @page_image = image(rendered.path, width: display_width, left: @pan, top: image_top, alt: "صفحة #{@reader.fetch(:number)} من الكتاب")
              click { |_button, x, _y| @drag = [x, @pan] unless @dialog }
              motion do |x, _y|
                next unless @drag && !@dialog && display_width > @pdf_width

                @pan = (@drag[1] + x - @drag[0]).clamp(@pdf_width - display_width, 0).round
                @page_image.move(@pan, image_top)
              end
              release { @drag = nil }
            end
          else
            para "جارٍ تحميل الكتاب المصوّر…", margin: 24, size: 15, stroke: muted
          end
        end
      end

      def save_page_image
        path = ask_save_file
        return if !path || path.empty?

        FileUtils.cp(@reader.fetch(:image).path, path)
      end

      def draw_export
        downloaded = @downloaded_ids.include?(@reader.fetch(:book).fetch("id"))
        action(downloaded ? "متاح دون اتصال" : "تنزيل الكتاب للقراءة دون اتصال", icon: downloaded ? "check" : "download",
          width: 1.0, state: downloaded ? "disabled" : nil) { queue_download(@reader.fetch(:book)) }
        para "أو احفظ ملفًا بصيغة تختارها.", top: 50, size: 14, stroke: muted
        @export_feedback = para "", top: 80, size: 14, stroke: muted
        stack(top: 112, width: 1.0, height: @content_height - 112, scroll: true) do
          @reader.fetch(:files).each do |file|
            flow(height: 54) do
              %w[pdf txt docx].each do |format|
                action(format.upcase, width: 70, margin_right: 8, state: file.dig("urls", format).to_s.empty? ? "disabled" : nil) { export_file(file, format) }
              end
              para file.fetch("name"), width: -250, size: 15, margin_top: 10
            end
          end
        end
      end

      def export_file(file, format)
        path = ask_save_file
        return if !path || path.empty?

        dialog = @dialog
        @export_feedback.text = "جارٍ حفظ الملف…"
        @download_worker.submit(-> { HTTP.new.download(file.fetch("urls").fetch(format), path, validate_pdf: format == "pdf") }) do |_result, error|
          next unless @dialog.equal?(dialog)

          @export_feedback.text = error ? error_message(error) : "تم حفظ الملف"
        end
      end
    end
  end
end
