# frozen_string_literal: true

module Aljam3
  module UI
    module Catalog
      def draw_catalog
        saved, authors = @screen == :saved, @screen == :authors
        heading = { saved: "كتبي المحمّلة", authors: "المؤلفون", browse: "الكتب", home: "نتائج البحث" }.fetch(@screen)
        para @scope_label || heading, font: HEADING_FONT, size: 24
        description = if saved
          "#{@downloaded_ids.length} كتاب للقراءة والبحث دون اتصال."
        elsif authors
          "ابحث عن مؤلف لاستكشاف كتبه."
        else
          "ابحث في النصوص أو العناوين، ثم افتح الكتاب أو نزّله."
        end
        para description, size: 15, stroke: muted, margin_top: 8
        search_scope_control(top: 64) unless authors
        form_top = authors ? 72 : 112
        search_form(top: form_top)
        row(top: form_top + 56) do
          unless authors
            tabs({ content: "النصوص", books: "العناوين" }, selected: @mode, width: 208) { |mode| switch_search_mode(mode) }
            action("تصفية#{@filters.empty? ? '' : " · #{@filters.length}"}", icon: "sliders-horizontal",
              width: 116, margin_left: 12) { open_filters }
          end
          para catalog_count, width: authors ? 1.0 : -324, size: 14, stroke: muted, align: authors ? "right" : "left"
        end
        result_top = form_top + 108
        if @mode == :content && !@query.strip.empty? && (@search_scope == :downloaded || (@result ? @source != :online : %i[offline unavailable].include?(@connection)))
          tabs({ relevance: "الأكثر صلة", library: "ترتيب المكتبة" }, selected: @search_order, width: 260,
            right: 0, top: result_top) do |order|
            @search_order = order
            request_catalog
          end
          result_top += 52
        end
        @results = scroll_area(top: result_top, height: [@content_height - result_top, 100].max) do
          if @busy && !@result
            empty_state("جارٍ البحث…", "نبحث في المكتبة عن النتائج.", icon: "search")
          elsif @error
            empty_state("تعذّر إكمال البحث", @error, action_label: "إعادة المحاولة") { request_catalog }
          elsif @result
            ranking_notice(@result.data) { request_catalog(expand: true) }
            items = @result.data.fetch(result_key)
            if items.empty?
              empty_library = saved && @downloaded_ids.empty?
              empty_state(empty_library ? "مكتبتك تبدأ بكتاب" : "لا توجد نتائج", empty_library ? "نزّل كتابًا لتقرأه وتبحث فيه أينما كنت." : "جرّب كلمات أخرى أو امسح البحث والتصفية.",
                action_label: empty_library ? "تصفح الكتب" : "مسح البحث") do
                if empty_library
                  navigate(:browse)
                else
                  @query, @filters, @scope_label = "", {}, nil
                  request_catalog
                end
              end
            elsif result_key == "pages"
              items.each { |item| search_row(item, query: @result_query) }
            else
              columns = @main_width >= 940 ? 2 : 1
              grid(items, columns:) do |item, styles|
                result_key == "authors" ? author_row(item, **styles) : book_row(item, **styles)
              end
            end
            page = @result.data.fetch("pagination").fetch("current_page")
            page_controls(page:, previous: page > 1, following: next_result_page) { |number| request_catalog(page: number) }
          end
        end
      end

      def search_form(top:)
        row(top:, height: 44) do
          @query_field = input(@query, width: -92, height: 44, margin_right: 12,
            placeholder: @screen == :authors ? "اسم المؤلف" : "ابحث عن كلمة، عبارة، أو عنوان كتاب…",
            tooltip: @screen == :authors ? "البحث عن مؤلف" : "البحث في الكتب والنصوص") { |field| @query = field.text }
          @query_field.finish = proc { request_catalog }
          action("بحث", icon: "search", width: 92, height: 44, variant: :solid) { request_catalog }
        end
      end

      def search_scope_control(top:)
        row(top:) do
          para "نطاق البحث", width: 92, size: 14, stroke: muted
          tabs({ all: "كل المكتبة", downloaded: "كتبي المحمّلة" }, selected: @search_scope, width: 280) do |scope|
            @search_scope = scope
            @screen = :browse if @screen == :saved && scope == :all
            if @screen == :home && @query.empty?
              draw_window
            else
              request_catalog
            end
          end
        end
      end

      def switch_search_mode(mode)
        @filters_by_mode ||= {}
        @filters_by_mode[@mode] = @filters
        @mode = mode
        @filters = @filters_by_mode.fetch(mode, {})
        request_catalog
      end

      def catalog_count
        return @busy ? "جارٍ البحث…" : "" if @error || !@result

        return "#{@result.data.fetch('pagination').fetch('count')} مؤلف" if result_key == "authors"

        "#{result_count(@result.data)} · #{@source == :online ? 'كل المكتبة' : 'المحفوظ على جهازك'}"
      end

      def book_heading(book, aligned: false)
        category, author = book.values_at("category", "author")
        stack(height_group: aligned ? "book_category" : nil) do
          if category
            para text_link(Text.plain(category.fetch("name")), stroke: muted) { browse_scope(:category, category) }, size: 13
          end
        end
        stack(height_group: aligned ? "book_title" : nil, margin_top: category || aligned ? 8 : 0) do
          para text_link(Text.plain(book.fetch("title"))) { open_book(book) }, size: 20, weight: "semibold"
        end
        stack(height_group: aligned ? "book_author" : nil, margin_top: author || aligned ? 8 : 0) do
          if author
            para text_link(Text.plain(author.fetch("name")), stroke: muted) { browse_scope(:author, author) }, size: 14
          end
        end
      end

      def book_row(book, **styles)
        card(**styles) do
          stack(padding: 16) { book_heading(book, aligned: true) }
          book_footer(book, "#{book.fetch('pages_count')} صفحة · #{book.fetch('files_count')} ملف")
        end
      end

      def search_row(hit, query: @query)
        book = hit.fetch("book")
        in_book = @dialog&.dig(:type) == :book_search
        card do
          stack(padding: 16) do
            if in_book
              row do
                para "صفحة #{hit.fetch('number')}", width: -124, size: 16
                action("عرض الصفحة", icon: "book-open", width: 124) { open_book(book, hit:, query:) }
              end
            else
              book_heading(book)
            end
            expanded = @expanded[hit.fetch("id")]
            content = Text.plain(hit.fetch("content"))
            excerpt = expanded ? content : Text.excerpt(hit.fetch("excerpt", content), query, length: 300)
            para(*highlighted(excerpt, query), font: READING_FONT, size: 19, leading: 8, margin_top: 16)
            if content.length > 300
              para text_link(expanded ? "إخفاء" : "اقرأ المزيد", stroke: primary) {
                @expanded[hit.fetch("id")] = !expanded
                draw_window
              }, size: 14, margin_top: 8
            end
          end
          book_footer(book, "صفحة #{hit.fetch('number')}", hit:, query:) unless in_book
        end
      end

      def book_footer(book, label, hit: nil, query: nil)
        separator
        row(height: 68, margin: [16, 16, 16, 16]) do
          para "#{label} · #{availability_label(book)}", width: -160, size: 13, stroke: muted
          action(hit ? "عرض الصفحة" : "قراءة", icon: "book-open", width: 124, margin_right: 8,
            state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book, hit:, query:) }
          if @downloaded_ids.include?(book.fetch("id"))
            icon_button("trash-2", "إزالة النسخة المحمّلة", key: [:remove_download, book.fetch("id")]) { confirm_remove_download(book) }
          elsif @download_queue.entry(book.fetch("id"))
            icon_button("download", "إدارة التنزيل") { navigate(:downloads) }
          else
            icon_button("download", "تنزيل الكتاب") { queue_download(book) }
          end
        end
      end
    end
  end
end
