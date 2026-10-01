# frozen_string_literal: true

module Aljam3
  module UI
    module Catalog
      def draw_catalog
        saved = @screen == :saved
        para saved ? "كتبي المحمّلة" : "المكتبة", font: HEADING_FONT, size: 26
        para saved ? "#{@downloaded_ids.length} كتاب للقراءة والبحث دون اتصال." : "كتب التراث الإسلامي، في مكان واحد.", size: 15, stroke: MUTED, margin_top: 8
        flow(top: 70, width: 1.0, height: 62) do
          action("بحث", width: 88, height: 61, margin_right: 12, margin_top: 21, variant: :solid) { request_catalog }
          stack(width: -88) do
            para saved ? "ابحث في عناوين كتبك" : "البحث في الكتب والنصوص", size: 13, stroke: MUTED, margin_bottom: 5
            @query_field = edit_line(@query, width: 1.0, align: "right") { |field| @query = field.text }
            @query_field.finish = proc { request_catalog }
          end
        end
        flow(top: 148, width: 1.0, height: 38) do
          reset = !@query.empty? || @category
          fixed = (saved ? 208 : 400) + (reset ? 44 : 0)
          para catalog_count, width: -fixed, size: 14, stroke: MUTED, align: "left", margin_top: 9
          icon_button("x", "مسح البحث والتصفية", margin_right: 8, width: 44) { @query, @category = "", nil; request_catalog } if reset
          action(selected_category_label[0, 25], width: 208, icon: "sliders-horizontal", margin_right: 12) do
            open_picker("تصفية حسب التصنيف", [["جميع التصنيفات", nil], *@categories.map { |category| [category.fetch("name"), category.fetch("id")] }]) do |category|
              @category = category
              request_catalog
            end
          end
          unless saved
            tabs({ books: "العناوين", content: "النصوص" }, selected: @mode, width: 192) { |mode| @mode = mode; request_catalog }
          end
        end
        @results = stack(top: 202, width: 1.0, height: [@content_height - 252, 100].max, scroll: true) do
          if @busy
            empty_state("جارٍ تحميل الكتب…", "نبحث في المكتبة عن النتائج.", icon: "search")
          elsif @error
            empty_state("تعذّر إكمال البحث", @error, action_label: "إعادة المحاولة") { request_catalog }
          elsif @result
            content = @result.data.key?("pages")
            items = @result.data.fetch(content ? "pages" : "books")
            if items.empty?
              empty_state(saved ? "مكتبتك تبدأ بكتاب" : "لا توجد نتائج",
                saved ? "نزّل كتابًا لتقرأه وتبحث فيه أينما كنت." : "جرّب كلمات أخرى أو امسح التصفية.",
                action_label: saved ? "تصفح المكتبة" : "مسح البحث") { navigate(:browse) }
            else
              items.each { |item| content ? search_row(item) : book_row(item) }
            end
          end
        end
        draw_pagination if @result && !@busy && !@error
      end

      def catalog_count
        return "" if @busy || @error || !@result

        count = @result.data.fetch("pagination").fetch("count")
        scope = %i[offline local].include?(@source) ? (@query.empty? ? "من الفهرس المحفوظ" : "في الكتب المحمّلة") : ""
        "#{count} #{@result.data.key?('pages') ? 'نتيجة' : 'كتاب'}  #{scope}"
      end

      def card
        stack(margin_bottom: 12, margin_right: 12) do
          background PAPER, curve: CARD_RADIUS
          border LINE, curve: CARD_RADIUS
          yield
        end
      end

      def book_heading(book)
        para Text.plain(book.dig("category", "name")), size: 13, stroke: MUTED, margin_bottom: 7
        para Text.plain(book.fetch("title")), size: 19, margin_bottom: 7
        para Text.plain(book.dig("author", "name")), size: 14, stroke: MUTED
      end

      def book_row(book)
        card do
          stack(margin: 16) { book_heading(book) }
          book_footer(book, "#{book.fetch('pages_count')} صفحة  ·  #{book.fetch('files_count')} ملف")
        end
      end

      def search_row(hit, query: @query)
        book = hit.fetch("book")
        card do
          stack(margin: 16) do
            book_heading(book)
            para(*highlighted(Text.excerpt(hit.fetch("excerpt", hit.fetch("content")), query, length: 260), query),
              font: READING_FONT, size: 19, leading: 7, margin_top: 14)
          end
          book_footer(book, "صفحة #{hit.fetch('number')}", page_id: hit.fetch("id"))
        end
      end

      def book_footer(book, label, page_id: nil)
        stack(height: 52) do
          line 1, 0, @main_width - 13, 0, stroke: LINE
          flow(left: 16, top: 9, width: @main_width - 44, height: 34) do
            control = book_action(book, page_id:)
            available = @downloaded_ids.include?(book.fetch("id")) ? "محفوظ  ·  " : ""
            para "#{available}#{label}", width: -control.width, size: 14, stroke: MUTED, margin_top: 7
          end
        end
      end

      def book_action(book, page_id: nil)
        id = book.fetch("id")
        if @downloaded_ids.include?(id)
          action(page_id ? "عرض الصفحة" : "قراءة", icon: "book-open", width: 126, height: 34) { open_book(book, page_id:) }
        elsif %i[queued downloading].include?(@downloads.dig(id, :status))
          action("قيد التنزيل", width: 126, height: 34) { navigate(:downloads) }
        else
          action(page_id ? "تنزيل وقراءة" : "تنزيل الكتاب", icon: "download", width: 138, height: 34) { queue_download(book, page_id:) }
        end
      end

      def draw_pagination(result = @result, &request)
        request ||= ->(page) { request_catalog(page:) }
        pagination = result.data.fetch("pagination")
        current, total = pagination.values_at("current_page", "total_pages")
        total = [total, 1].max
        flow(top: @content_height - 38, width: 1.0, height: 36) do
          action("التالي", icon: "arrow-left", width: 92, margin_right: 8, state: current >= total ? "disabled" : nil) { request.call(current + 1) }
          action("السابق", icon: "arrow-right", width: 92, state: current <= 1 ? "disabled" : nil) { request.call(current - 1) }
          para "الصفحة #{current} من #{total}", width: -184, size: 14, stroke: MUTED, margin_top: 8
        end
      end

      def draw_picker
        action("رجوع", icon: "arrow-right", left: 0, top: 0, width: 96, variant: :ghost) { close_picker }
        para @picker.fetch(:heading), left: 110, top: 0, width: @main_width - 110, font: HEADING_FONT, size: 24
        para "ابحث في القائمة", top: 58, size: 14, stroke: MUTED
        edit_line(@picker.fetch(:query), top: 82, width: 1.0, align: "right") do |field|
          @picker[:query] = field.text
          draw_choices
        end
        @choices = stack(top: 142, width: 1.0, height: @content_height - 146, scroll: true)
        draw_choices
      end

      def draw_choices
        choices = @picker.fetch(:choices).select { |label, _| Text.normalize(label).include?(Text.normalize(@picker.fetch(:query))) }
        @choices.clear do
          if choices.empty?
            empty_state("لا توجد خيارات مطابقة", "جرّب كلمات أخرى.", icon: "search")
          else
            choices.each do |label, value|
              action(label, width: 1.0, height: 44, margin_bottom: 8, margin_right: 12, variant: :ghost) do
                @screen = @picker.fetch(:return_screen)
                @picker.fetch(:selection).call(value)
              end
            end
          end
        end
      end

      def draw_downloads
        para "التنزيلات", font: HEADING_FONT, size: 26
        para "الكتاب المصوّر ونصه، للقراءة دون اتصال.", size: 15, stroke: MUTED, margin_top: 8
        stack(top: 88, width: 1.0, height: @content_height - 88, scroll: true) do
          if @downloads.empty?
            empty_state("لا توجد تنزيلات جارية", "الكتب التي نزّلتها سابقًا موجودة في «كتبي المحمّلة».",
              icon: "download", action_label: "تصفح المكتبة") { navigate(:browse) }
          else
            @downloads.each do |id, download|
              card do
                stack(margin: 16) do
                  book_heading(download.fetch(:book))
                  label = para download.fetch(:message), size: 15, stroke: MUTED, margin_top: 16
                  bar = progress(width: 1.0, margin_top: 10)
                  bar.fraction = download.fetch(:fraction)
                  @progress_views[id] = { label:, bar: }
                  case download.fetch(:status)
                  when :done then action("قراءة", icon: "book-open", margin_top: 12) { open_book(download.fetch(:book)) }
                  when :failed then action("إعادة المحاولة", margin_top: 12) { queue_download(download.fetch(:book)) }
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
