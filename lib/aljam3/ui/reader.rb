# frozen_string_literal: true

module Aljam3
  module UI
    module Reader
      def open_book(book, page_id: nil, hit: nil, query: nil)
        @store.cancel_search
        if offline_unavailable?(book)
          open_dialog(:unavailable, book:)
          return
        end
        remember_location
        unless @screen == :reader
          @catalog_return = { screen: @screen, scroll: @results&.scroll_top || 0 }
        end
        @navigation_motion = 0
        @dialog = @results = @dialog_scroll = nil
        @dialog_stack = []
        @request_number += 1
        if @store.downloaded?(book.fetch("id"))
          location = hit || (page_id && @store.find_page(page_id))
          location = @store.find_page(location.fetch("id")) if location && !location["file_id"]
          notice = "لم نجد صفحة النتيجة في النسخة المحمّلة. فُتحت بداية الكتاب." if (hit || page_id) && !location
          start_reader(book.merge("files" => @store.files(book.fetch("id"))), location:, notice:, query:)
        else
          request_number = @request_number
          @screen = :opening
          draw_window
          @network_worker.submit(-> {
            next unless @request_number == request_number && @screen == :opening

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
              start_reader(data.first, location: data.last, query:)
            end
          end
        end
      end

      def start_reader(book, location: nil, notice: nil, query: nil)
        files = book.fetch("files")
        raise ResponseError.new(404), "This book has no files." if files.empty?

        saved = @store.preference("reading:#{book.fetch('id')}", {})
        location ||= saved
        file = files.find { |candidate| candidate.fetch("id") == location["file_id"] }
        options = @store.preference("reader", {})
        @store.cache_books([book])
        @bookmarks = @store.bookmarks(book.fetch("id"))
        @reader = { book:, files:, file: file || files.first, zoom: 1.0,
          mode: options.fetch("mode", "split").to_sym, text_size: options.fetch("text_size", 20),
          tashkeel: options.fetch("tashkeel", true), split_ratio: options.fetch("split_ratio", 0.5), query: query.to_s }
        @screen = :reader
        turn_page(file ? location.fetch("number", 1) : 1, notice:)
      end

      def close_reader
        return navigate_history(:back) if @history&.back?

        @page_request = (@page_request || 0) + 1
        @render_number = (@render_number || 0) + 1
        @screen = @catalog_return.fetch(:screen)
        @navigation_motion = 0
        draw_window
        @results.scroll_top = @catalog_return.fetch(:scroll) if @results
      end

      def save_reader_options
        @store.save_preference("reader", @reader.slice(:mode, :text_size, :tashkeel, :split_ratio))
      end

      def draw_reader
        @pdf_surface = @text_surface = @page_image = @copy_button = @page_text = @drag = nil
        @fit_button = @zoom_in_button = @zoom_out_button = nil
        book = @reader.fetch(:book)
        para Text.plain(book.fetch("title")), left: PAGE_MARGIN + 48, top: PAGE_TOP,
          width: @main_width - 48, size: 22, font: HEADING_FONT, wrap: "trim"
        icon_button("arrow-left", "العودة إلى النتائج", left: PAGE_MARGIN, top: PAGE_TOP - 4) { close_reader }
        author = book["author"]
        para text_link(Text.plain(author&.fetch("name")), stroke: muted) { browse_scope(:author, author) if author },
          left: PAGE_MARGIN + 184, top: PAGE_TOP + 36, width: @main_width - 184, size: 14
        @reader_availability = para availability_label(book), left: PAGE_MARGIN, top: PAGE_TOP + 36, width: 176, size: 13, stroke: muted, align: "left"
        reader_toolbar(PAGE_TOP + 68)
        pane_top = PAGE_TOP + 132
        unless @reader.fetch(:query).empty?
          reader_match_bar(pane_top)
          pane_top += 44
        end
        if @reader[:notice]
          para @reader[:notice], left: PAGE_MARGIN, top: pane_top, width: @main_width, size: 14, stroke: primary
          pane_top += 32
        end
        pdf_width, text_width = reader_pane_widths
        pane_height = height - pane_top - STATUS_HEIGHT - 88
        @pane_top, @pane_height = pane_top, pane_height
        reader_pdf_pane(width: pdf_width, height: pane_height, top: pane_top) if reader_pdf?
        reader_text_pane(width: text_width, height: pane_height, top: pane_top) unless @reader[:mode] == :pdf
        draw_reader_divider if @reader[:mode] == :split
        reader_pagination
      end

      def reader_toolbar(top)
        stack(left: PAGE_MARGIN, top:, width: @main_width, height: 48, padding_left: 8, padding_right: 8, padding_top: 6, padding_bottom: 6) do
          background surface, curve: CARD_RADIUS
          row do
            action("بحث", icon: "search", width: 88, variant: :ghost) { open_book_search }
            @bookmark_button = icon_button(bookmarked? ? "bookmark-check" : "bookmark", bookmarked? ? "إزالة الفاصل" : "حفظ فاصل · Ctrl/⌘ D",
              selected: bookmarked?, toggled: bookmarked?) { toggle_reader_bookmark }
            @copy_button = icon_button("copy", "نسخ نص الصفحة", live: "polite", state: page_text.strip.empty? ? "disabled" : nil) { copy_page }
            action("خيارات القراءة", width: 128, variant: :ghost) { open_dialog(:reader_options) }
            icon_button("ellipsis", "أدوات الكتاب") { open_dialog(:reader_menu) }
            stack(width: reader_pdf? ? -728 : -620, height: 1)
            tabs({ text: "النص", split: "النص والصورة", pdf: "الصورة" }, selected: @reader[:mode], width: 280,
              widths: { text: 60, split: 132, pdf: 72 }) { |mode| change_reader_mode(mode) }
            stack(width: 16, height: 1)
            if reader_pdf?
              @zoom_in_button = icon_button("zoom-in", "تكبير PDF") { change_zoom(0.25) }
              @zoom_out_button = icon_button("zoom-out", "تصغير PDF") { change_zoom(-0.25) }
              @fit_button = icon_button("page-fit", "ملاءمة الصفحة داخل مساحة القراءة") { fit_pdf_page }
              update_pdf_controls
            end
          end
        end
      end

      def page_text
        page = @reader[:page] || (@store.downloaded?(@reader.fetch(:book).fetch("id")) && @store.page(@reader.fetch(:file).fetch("id"), @reader.fetch(:number)))
        text = Text.plain(page ? page.fetch("content") : "").gsub(/\r\n?/, "\n")
        @reader.fetch(:tashkeel) ? text : Text.without_tashkeel(text)
      end

      def reader_text_pane(width:, height:, top:)
        left = PAGE_MARGIN + (@reader[:mode] == :split ? @pdf_width + READER_GAP : 0)
        @text_pane = stack(left:, top:, width:, height:) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          @text_surface = stack(width: 1.0, height:, scroll: true, direction: "rtl") do
            stack(margin: 20) do
              if @reader[:text_error]
                para @reader[:text_error], size: 15, stroke: muted
                action("إعادة تحميل النص", margin_top: 16) { turn_page(@reader.fetch(:number)) }
              else
                content = @reader[:loading_text] ? "جارٍ تحميل النص…" : (page_text.strip.empty? ? "لا يتوفر نص لهذه الصفحة." : page_text)
                @page_text = para(*reader_text_parts(content), selectable: true, font: READING_FONT, size: @reader.fetch(:text_size), leading: 8)
                if !@reader[:loading_text] && @reader.delete(:focus_match)
                  page_text = @page_text
                  schedule_once(0) { focus_reader_match if @page_text == page_text && @screen == :reader }
                end
              end
            end
          end
        end
      end

      def copy_page
        copy_with_feedback(page_text, control: @copy_button)
      end

      def change_text_size(change)
        @reader[:text_size] = (@reader.fetch(:text_size) + change).clamp(17, 35)
        @page_text&.style(size: @reader.fetch(:text_size))
        save_reader_options
      end

      def toggle_tashkeel
        @reader[:tashkeel] = !@reader.fetch(:tashkeel)
        @page_text.replace(*reader_text_parts(page_text)) if @page_text && !@reader[:loading_text] && !@reader[:text_error]
        save_reader_options
      end

      def reader_pdf_pane(width:, height:, top:)
        @pdf_width, @pdf_height = width, height
        @pdf_pane = stack(left: PAGE_MARGIN, top:, width:, height:) do
          background surface, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          @pdf_surface = stack(width: 1.0, height:, scroll: true, direction: "rtl")
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
        bottom = height - STATUS_HEIGHT
        stack(left: PAGE_MARGIN, top: bottom - 68, width: @main_width, height: 52) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
        end
        row(left: (width - 340) / 2, top: bottom - 60, width: 340) do
          icon_button("chevrons-right", "أول صفحة", state: number <= 1 ? "disabled" : nil) { turn_page(1) }
          icon_button("arrow-right", "الصفحة السابقة", state: number <= 1 ? "disabled" : nil) { turn_page(number - 1) }
          para "الصفحة", width: 52, size: 14, align: "center", stroke: muted
          @page_field = input(number.to_s, width: 76, height: 36, align: "center", tooltip: "رقم الصفحة · Enter للانتقال") do
            @page_feedback.text = "" if @page_feedback
          end
          @page_field.finish = proc { go_to_page }
          para "من #{count}", width: 68, size: 14, align: "center", stroke: muted
          icon_button("arrow-left", "الصفحة التالية", state: number >= count ? "disabled" : nil) { turn_page(number + 1) }
          icon_button("chevrons-left", "آخر صفحة", state: number >= count ? "disabled" : nil) { turn_page(count) }
        end
        @page_feedback = para "", left: (width - 340) / 2, top: bottom - 86, width: 340, size: 13, stroke: primary, align: "center"
        files = @reader.fetch(:files)
        if files.size > 1
          action("ملفات الكتاب", icon: "chevron-down", right: PAGE_MARGIN + 12, top: bottom - 60, width: 144, variant: :ghost) do
            choices = files.map { |item| ["#{item.fetch('name')} · #{item.fetch('pages_count')} صفحة", item] }
            open_dialog(:volumes, query: "", choices:, selection: ->(selected) { @reader[:file] = selected; turn_page(1) })
          end
        end
      end

      def go_to_page
        number = Integer(@page_field.text.tr("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789"), 10, exception: false)
        count = @reader.fetch(:file).fetch("pages_count")
        if number && number.between?(1, count)
          turn_page(number)
        else
          @page_feedback.text = "أدخل رقم صفحة من 1 إلى #{count}."
          @page_field.focus
        end
      end

      def turn_page(number, notice: nil, restoring: false)
        @pending_location_scroll = nil unless restoring
        @editing_field = nil
        @text_surface = @pdf_surface = nil
        file, book = @reader.values_at(:file, :book)
        number = number.clamp(1, file.fetch("pages_count"))
        @reader.merge!(number:, notice:, image: nil, pdf_error: nil, page: nil, text_error: nil, match_index: 0, focus_match: true)
        @page_request = (@page_request || 0) + 1
        request_number = @page_request
        @store.save_reading(book.fetch("id"), file_id: file.fetch("id"), number:)
        if @store.downloaded?(book.fetch("id"))
          @reader[:page] = @store.page(file.fetch("id"), number)
          @reader[:loading_text] = false
        else
          @reader[:loading_text] = true
          @page_worker.submit(-> {
            @reading.page(book.fetch("id"), file.fetch("id"), number) if @screen == :reader && @page_request == request_number
          }) do |page, error|
            next unless @screen == :reader && @page_request == request_number

            @reader.merge!(page:, loading_text: false, text_error: error && error_message(error))
            refresh_window
          end
        end
        draw_window
        render_pdf if reader_pdf?
      end

      def change_zoom(change)
        zoom = (@reader.fetch(:zoom) + change).clamp(0.5, 3.0)
        return if zoom == @reader[:zoom]

        @reader[:zoom] = zoom
        update_pdf_controls
        render_pdf if reader_pdf?
      end

      def fit_pdf_page
        return if @reader.fetch(:zoom) == 1.0

        @pdf_surface.scroll_top = 0 if @pdf_surface
        change_zoom(1.0 - @reader.fetch(:zoom))
      end

      def update_pdf_controls
        ready = @reader[:image] && !@reader[:pdf_error]
        zoom = @reader.fetch(:zoom)
        @fit_button&.style(state: ready && zoom != 1.0 ? nil : "disabled")
        @zoom_in_button&.style(state: ready && zoom < 3.0 ? nil : "disabled")
        @zoom_out_button&.style(state: ready && zoom > 0.5 ? nil : "disabled")
      end

      def render_pdf
        @render_number = (@render_number || 0) + 1
        render_number = @render_number
        book, file, number, zoom = @reader.values_at(:book, :file, :number, :zoom)
        pane_width = @pdf_width
        check = -> { raise PDF::Cancelled unless @render_number == render_number && reader_pdf? }
        @render_worker.submit(-> {
          check.call
          source = @reading.pdf_source(book.fetch("id"), file)
          @pdf.render(source, page: number, width: (pane_width - 32) * zoom * 1.5, check:)
        }) do |rendered, error|
          next unless reader_pdf? && @render_number == render_number

          @reader.merge!(image: rendered, pdf_error: error && error_message(error))
          draw_pdf_image
        end
      end

      def draw_pdf_image
        return unless @pdf_surface

        @page_image = nil
        update_pdf_controls
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
        restore_navigation_scroll
      end
    end
  end
end
