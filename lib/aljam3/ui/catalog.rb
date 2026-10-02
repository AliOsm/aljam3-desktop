# frozen_string_literal: true

module Aljam3
  module UI
    module Catalog
      def draw_catalog
        saved = @screen == :saved
        heading = { saved: "كتبي المحمّلة", authors: "المؤلفون", browse: "الكتب", home: "نتائج البحث" }.fetch(@screen)
        para @scope_label || heading, font: HEADING_FONT, size: 24
        para saved ? "#{@downloaded_ids.length} كتاب للقراءة والبحث دون اتصال." : "اقرأ الآن، أو نزّل الكتاب للقراءة دون اتصال.",
          size: 14, stroke: muted, margin_top: 8
        search_scope_control(top: 60) unless @screen == :authors
        search_form(top: 106)
        flow(top: 164, width: 1.0, height: 38) do
          para source_label, width: -400, size: 13, stroke: muted, align: "left", margin_top: 10
          action("تصفية#{@filters.empty? ? '' : " · #{@filters.length}"}", icon: "sliders-horizontal", width: 116,
            margin_right: 12, state: @mode == :authors ? "disabled" : nil) { open_filters }
          if @screen == :authors
            para "#{@result&.data&.dig('pagination', 'count') || 0} #{saved ? 'كتاب' : 'مؤلف'}", width: 272, size: 14, stroke: muted, margin_top: 10
          else
            modes = saved ? { books: "العناوين", content: "النصوص" } : { authors: "المؤلفون", books: "العناوين", content: "النصوص" }
            tabs(modes, selected: @mode, width: 272) { |mode| switch_search_mode(mode) }
          end
        end
        para catalog_count, left: 282, width: @main_width - 282, top: 214, size: 14, stroke: muted
        if @result && result_key == "pages" && @source != :online
          tabs({ library: "ترتيب المكتبة", relevance: "الأكثر صلة" }, selected: @search_order, width: 266, left: 0, top: 206) do |order|
            @search_order = order
            request_catalog
          end
        end
        @results = stack(top: 244, width: 1.0, height: [@content_height - 244, 100].max, scroll: !@dialog) do
          if @busy && !@result
            empty_state("جارٍ البحث…", "نبحث في المكتبة عن النتائج.", icon: "search")
          elsif @error
            empty_state("تعذّر إكمال البحث", @error, action_label: "إعادة المحاولة") { request_catalog }
          elsif @result
            items = @result.data.fetch(result_key)
            if items.empty?
              empty_state(saved ? "مكتبتك تبدأ بكتاب" : "لا توجد نتائج", saved ? "نزّل كتابًا لتقرأه وتبحث فيه أينما كنت." : "جرّب كلمات أخرى أو امسح التصفية.",
                action_label: saved ? "تصفح الكتب" : "مسح البحث") { navigate(:browse) }
            else
              items.each do |item|
                case result_key
                when "pages" then search_row(item)
                when "authors" then author_row(item)
                else book_row(item)
                end
              end
            end
            page = @result.data.fetch("pagination").fetch("current_page")
            page_controls(page:, previous: page > 1, following: next_result_page) { |number| request_catalog(page: number) }
          end
        end
      end

      def search_form(top:)
        flow(top:, width: 1.0, height: 48) do
          action("بحث", width: 76, height: 44, margin_right: 12, variant: :solid) { request_catalog }
          @query_field = input(@query, width: -88, height: 44, tooltip: @screen == :authors ? "البحث عن مؤلف" : "البحث في الكتب والنصوص") { |field| @query = field.text }
          @query_field.finish = proc { request_catalog }
        end
      end

      def search_scope_control(top:)
        tabs({ downloaded: "كتبي المحمّلة", all: "كل المكتبة" }, selected: @search_scope, width: 290,
          left: @main_width - 290, top:) do |scope|
          @search_scope = scope
          @screen = :browse if @screen == :saved && scope == :all
          request_catalog unless @screen == :home && @query.empty?
          draw_window
        end
        para "نطاق البحث", left: @main_width - 390, top: top + 9, width: 84, size: 14, stroke: muted
      end

      def switch_search_mode(mode)
        @filters_by_mode ||= {}
        @filters_by_mode[@mode] = @filters
        @mode = mode
        @filters = @filters_by_mode.fetch(mode, {})
        request_catalog
      end

      def catalog_count
        return "" if @error || !@result

        scope = %i[offline local].include?(@source) && !@query.empty? ? " · في الكتب المحمّلة" : ""
        "#{result_count(@result.data)}#{scope}"
      end

      def card
        stack(margin_bottom: 12, margin_right: 12) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          yield
        end
      end

      def book_heading(book)
        category, author = book.values_at("category", "author")
        if category
          para text_link(Text.plain(category.fetch("name")), stroke: muted) { browse_scope(:category, category) }, size: 13, margin_bottom: 8
        end
        para text_link(Text.plain(book.fetch("title"))) { open_book(book) }, size: 19, weight: "semibold", margin_bottom: 6
        if author
          para text_link(Text.plain(author.fetch("name")), stroke: muted) { browse_scope(:author, author) }, size: 14
        end
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
            expanded = @expanded[hit.fetch("id")]
            content = Text.plain(hit.fetch("content"))
            excerpt = expanded ? content : Text.excerpt(hit.fetch("excerpt", content), query, length: 300)
            para(*highlighted(excerpt, query), font: READING_FONT, size: 18, leading: 7, margin_top: 12)
            if content.length > 300
              para text_link(expanded ? "إخفاء" : "اقرأ المزيد", stroke: primary) {
                @expanded[hit.fetch("id")] = !expanded
                draw_window
              }, size: 13, margin_top: 6
            end
          end
          book_footer(book, "صفحة #{hit.fetch('number')}", hit:, query:)
        end
      end

      def book_footer(book, label, hit: nil, query: nil)
        stack(height: 52) do
          line 1, 0, @main_width - 13, 0, stroke: line_color
          flow(left: 16, top: 9, width: @main_width - 44, height: 34) do
            action(hit ? "عرض الصفحة" : "قراءة", icon: "book-open", width: 110, height: 34,
              state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book, hit:, query:) }
            if @downloaded_ids.include?(book.fetch("id"))
              icon_button("trash-2", "إزالة النسخة المحمّلة", height: 34) { confirm_remove_download(book) }
            elsif @download_queue.entry(book.fetch("id"))
              icon_button("download", "إدارة التنزيل", height: 34) { navigate(:downloads) }
            else
              icon_button("download", "تنزيل الكتاب", height: 34) { queue_download(book) }
            end
            para "#{label}  ·  #{availability_label(book)}", width: -160, size: 13, stroke: muted, margin_top: 8
          end
        end
      end

    end
  end
end
