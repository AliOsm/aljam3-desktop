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
          tashkeel: options.fetch("tashkeel", true), split_ratio: options.fetch("split_ratio", 0.5), pdf_appearance: options.fetch("pdf_appearance", "auto"), query: query.to_s }
        @screen = :reader
        turn_page(file ? location.fetch("number", 1) : 1, notice:)
      end

      def close_reader
        save_reader_position
        return navigate_history(:back) if @history&.back?

        @page_request = (@page_request || 0) + 1
        @render_number = (@render_number || 0) + 1
        @screen = @catalog_return.fetch(:screen)
        @navigation_motion = 0
        draw_window
        @results.scroll_top = @catalog_return.fetch(:scroll) if @results
      end

      def save_reader_options
        @store.save_preference("reader", @reader.slice(:mode, :text_size, :tashkeel, :split_ratio, :pdf_appearance))
      end

      def draw_reader
        @pdf_pinch = nil
        @pdf_surface = @text_surface = @text_content = @page_image = @copy_button = @page_text = @drag = nil
        @fit_button = @zoom_in_button = @zoom_out_button = @match_label = nil
        @previous_match_button = @next_match_button = nil
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
            @text_content = stack(margin: 20)
          end
        end
        update_reader_text(restore: false)
      end

      def update_reader_text(restore: true)
        return unless @text_content

        @page_text = nil
        @text_content.clear do
          if @reader[:text_error]
            para @reader[:text_error], size: 15, stroke: muted
            action("إعادة تحميل النص", margin_top: 16) { load_reader_text }
          else
            content = @reader[:loading_text] ? "جارٍ تحميل النص…" : (page_text.strip.empty? ? "لا يتوفر نص لهذه الصفحة." : page_text)
            @page_text = para(*reader_text_parts(content), selectable: true, cursor: "text", font: READING_FONT, size: @reader.fetch(:text_size), leading: 8)
            @page_text.click { |button, x, y| open_reader_copy_menu(x, y) if button == 3 }
          end
        end
        @copy_button&.style(state: @reader[:loading_text] || page_text.strip.empty? ? "disabled" : nil)
        if @match_label
          count = Text.match_ranges(page_text, @reader.fetch(:query)).length
          @match_label.text = "#{format_number(count.zero? ? 0 : @reader.fetch(:match_index, 0) + 1)} / #{format_number(count)} في الصفحة"
          [@previous_match_button, @next_match_button].compact.each { |button| button.state = count.zero? ? "disabled" : nil }
        end
        if !@reader[:loading_text] && @reader.delete(:focus_match)
          control = @page_text
          schedule_once(0) { focus_reader_match if @screen == :reader && @page_text == control }
        end
        restore_navigation_scroll if restore
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

      def reader_pdf? = @screen == :reader && %i[pdf split].include?(@reader.fetch(:mode))

      def change_reader_mode(mode)
        return if @reader[:mode] == mode

        remember_pdf_anchor
        @reader[:mode] = mode
        invalidate_pdf_render
        @pdf_scroll_pending = @pdf_render_due = nil
        save_reader_options
        draw_window
        render_pdf if reader_pdf?
      end

      def reader_pagination
        number, file = @reader.values_at(:number, :file)
        count = file.fetch("pages_count")
        count_text = format_number(count)
        field_width = [76, count_text.length * 10 + 24].max
        count_width = [68, count_text.length * 8 + 28].max
        controls_width = 196 + field_width + count_width
        bottom = height - STATUS_HEIGHT
        stack(left: PAGE_MARGIN, top: bottom - 68, width: @main_width, height: 52) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
        end
        row(left: (width - controls_width) / 2, top: bottom - 60, width: controls_width) do
          @first_page_button = icon_button("chevrons-right", "أول صفحة", state: number <= 1 ? "disabled" : nil) { turn_page(1) }
          @previous_page_button = icon_button("arrow-right", "الصفحة السابقة", state: number <= 1 ? "disabled" : nil) { turn_page(@reader.fetch(:number) - 1) }
          para "الصفحة", width: 52, size: 14, align: "center", stroke: muted
          @page_field = input(format_number(number), width: field_width, height: 36, align: "center", tooltip: "رقم الصفحة · Enter للانتقال") do
            @page_feedback.text = "" if @page_feedback
          end
          @page_field.finish = proc { go_to_page }
          para "من #{count_text}", width: count_width, size: 14, align: "center", stroke: muted
          @next_page_button = icon_button("arrow-left", "الصفحة التالية", state: number >= count ? "disabled" : nil) { turn_page(@reader.fetch(:number) + 1) }
          @last_page_button = icon_button("chevrons-left", "آخر صفحة", state: number >= count ? "disabled" : nil) { turn_page(count) }
        end
        @page_feedback = para "", left: (width - controls_width) / 2, top: bottom - 86, width: controls_width, size: 13, stroke: primary, align: "center"
        files = @reader.fetch(:files)
        if files.size > 1
          action("ملفات الكتاب", icon: "chevron-down", right: PAGE_MARGIN + 12, top: bottom - 60, width: 144, variant: :ghost) do
            choices = files.map { |item| ["#{item.fetch('name')} · #{format_number(item.fetch('pages_count'))} صفحة", item] }
            open_dialog(:volumes, query: "", choices:, selection: ->(selected) { @reader[:file] = selected; turn_page(1) })
          end
        end
      end

      def go_to_page
        text = @page_field.text.strip.tr("٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "01234567890123456789")
        number = Integer(text.delete(","), 10, exception: false) if text.match?(/\A(?:\d+|\d{1,3}(?:,\d{3})+)\z/)
        count = @reader.fetch(:file).fetch("pages_count")
        if number && number.between?(1, count)
          turn_page(number)
        else
          @page_feedback.text = "أدخل رقم صفحة من 1 إلى #{format_number(count)}."
          @page_field.focus
        end
      end

      def turn_page(number, notice: nil, restoring: false)
        @pending_location_scroll = nil unless restoring
        @editing_field = nil
        notice_changed = @reader[:notice] != notice
        @reader[:notice] = notice
        same_volume = @pdf_volume == reader_volume && @pdf_surface
        @reader[:number] = number.clamp(1, @reader.fetch(:file).fetch("pages_count"))
        @reader[:pdf_anchor] = nil unless restoring
        @pdf_surface = @text_surface = @text_content = nil unless same_volume
        prepare_pdf_volume
        invalidate_pdf_render
        activate_reader_page(@reader.fetch(:number))
        if same_volume && !notice_changed
          jump_pdf_page(@reader.fetch(:number))
        else
          @text_surface = @pdf_surface = nil
          draw_window
        end
        render_pdf if reader_pdf?
      end

      def activate_reader_page(number, delay: false)
        @reader.merge!(number:, page: nil, image: @pdf_images&.[](number), pdf_error: nil,
          text_error: nil, loading_text: true, match_index: 0, focus_match: true)
        @page_request = (@page_request || 0) + 1
        @text_surface.scroll_top = 0 if @text_surface
        update_reader_text
        update_reader_page_controls
        if delay
          @text_load_due = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.12
          start_reader_pump
        else
          load_reader_text
        end
      end

      def load_reader_text
        @text_load_due = nil
        file, book, number = @reader.values_at(:file, :book, :number)
        save_reader_position
        if @reader[:text_error]
          @reader.merge!(loading_text: true, text_error: nil)
          update_reader_text
        end
        request_number = @page_request
        if @store.downloaded?(book.fetch("id"))
          @reader.merge!(page: @store.page(file.fetch("id"), number), loading_text: false)
          update_reader_text
        else
          @page_worker.submit(-> {
            @reading.page(book.fetch("id"), file.fetch("id"), number) if @screen == :reader && @page_request == request_number
          }) do |page, error|
            next unless @screen == :reader && @page_request == request_number

            @reader.merge!(page:, loading_text: false, text_error: error && error_message(error))
            update_reader_text
          end
          start_reader_pump
        end
      end

      def save_reader_position
        @store.save_reading(@reader.fetch(:book).fetch("id"), file_id: @reader.fetch(:file).fetch("id"), number: @reader.fetch(:number))
      end

      def update_reader_page_controls
        number = @reader.fetch(:number)
        last = number >= @reader.fetch(:file).fetch("pages_count")
        @page_field.text = format_number(number) if @page_field && @editing_field != @page_field
        [@first_page_button, @previous_page_button].compact.each { |button| button.state = number <= 1 ? "disabled" : nil }
        [@last_page_button, @next_page_button].compact.each { |button| button.state = last ? "disabled" : nil }
        @bookmark_button&.style(icon: asset_path("icons", bookmarked? ? "bookmark-check" : "bookmark"),
          color: bookmarked? ? accent : "transparent", toggled: bookmarked?, tooltip: bookmarked? ? "إزالة الفاصل" : "حفظ فاصل · Ctrl/⌘ D")
        update_pdf_controls
      end
    end
  end
end
