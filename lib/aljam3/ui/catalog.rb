# frozen_string_literal: true

module Aljam3
  module UI
    module Catalog
      def draw_catalog
        saved, authors = @screen == :saved, @screen == :authors
        heading = { saved: "كتبي المحمّلة", authors: "المؤلفون", browse: "الكتب", home: "نتائج البحث" }.fetch(@screen)
        para @scope_label || heading, font: HEADING_FONT, size: 24
        description = if saved
          "#{format_number(@downloaded_ids.length)} كتاب للقراءة والبحث دون اتصال."
        elsif authors
          "ابحث عن مؤلف لاستكشاف كتبه."
        else
          "ابحث في النصوص أو العناوين، ثم افتح الكتاب أو نزّله."
        end
        para description, size: 15, stroke: muted, margin_top: 8
        search_controls(top: 64) unless authors
        form_top = authors ? 72 : 112
        search_form(top: form_top)
        sortable = @mode == :content && !@query.strip.empty? &&
          (@search_scope == :downloaded || (@result ? @source != :online : %i[offline unavailable].include?(@connection)))
        row(top: form_top + 56) do
          para catalog_count, width: sortable ? -224 : 1.0, size: 14, stroke: muted
          if sortable
            para "الترتيب:", width: 52, margin_right: 8, size: 14, stroke: muted
            dropdown({ relevance: "الأكثر صلة", library: "ترتيب المكتبة" }, selected: @search_order,
              key: :search_order, tooltip: "ترتيب نتائج البحث", width: 172) do |order|
              @search_order = order
              request_catalog
            end
          end
        end
        result_top = form_top + 104
        unless refinement_filters.empty? || authors
          active_filters(top: result_top)
          result_top += 48
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
                  @query, @filters = "", (@scope_filters || {}).dup
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
        placeholder = if @screen == :authors
          "ابحث عن اسم المؤلف…"
        elsif @mode == :books
          "ابحث عن عنوان كتاب…"
        else
          "ابحث عن كلمة أو عبارة في نصوص الكتب…"
        end
        row(top:, height: 44) do
          @query_field = input(@query, width: -92, height: 44, margin_right: 12,
            placeholder:, tooltip: placeholder.delete_suffix("…")) { |field| @query = field.text }
          @query_field.finish = proc { request_catalog }
          action("بحث", icon: "search", width: 92, height: 44, variant: :solid) { request_catalog }
        end
      end

      def search_controls(top:)
        row(top:) do
          para "البحث في:", align: "left", margin_right: 8, size: 14, stroke: muted
          dropdown({ books: "عناوين الكتب", content: "نصوص الكتب" }, selected: @mode,
            key: :search_mode, tooltip: "البحث في النصوص أو العناوين", width: 168, margin_right: 20) { |mode| switch_search_mode(mode) }
          para "ضمن:", align: "left", margin_right: 8, size: 14, stroke: muted
          dropdown({ all: "كل المكتبة", downloaded: "كتبي المحمّلة" }, selected: @search_scope,
            key: :search_scope, tooltip: "الكتب المشمولة في البحث", width: 176, margin_right: 20) do |scope|
            @search_scope = scope
            @screen = :browse if @screen == :saved && scope == :all
            refresh_search
          end
          action("تصفية#{@filters.empty? ? '' : " · #{format_number(@filters.length)}"}", icon: "sliders-horizontal", key: :filters,
            width: 104) { open_filters }
        end
      end

      def filter_label(key, id)
        entity = case key
        when :library then @libraries.find { |library| library.fetch("id") == id }
        when :category then @categories.find { |category| category.fetch("id") == id }
        when :author then @store.author(id)
        end
        return Text.plain(entity.fetch("name")) if entity
        return @scope_label if @scope_label && @scope_filters&.[](key) == id

        { library: "المكتبة", category: "التصنيف", author: "المؤلف" }.fetch(key)
      end

      def apply_filters(filters)
        scope = filters.slice(*(@scope_filters || {}).keys)
        if scope != (@scope_filters || {})
          remember_location
          @scope_label = scope.empty? ? nil : filter_label(*scope.first)
        end
        @filters, @scope_filters = filters.dup, scope.freeze
        @dialog = @dialog_scroll = nil
        @screen = :browse if @screen == :home && @query.strip.empty?
        request_catalog
      end

      def refinement_filters
        @filters.reject { |key, id| (@scope_filters || {})[key] == id }
      end

      def active_filters(top:)
        row(top:) do
          refinements = refinement_filters
          refinements.each_with_index do |(key, id), index|
            label = filter_label(key, id)
            gap = index < refinements.length - 1 ? 8 : 0
            action(label, icon: "x", icon_pos: "left", tooltip: "إزالة التصفية: #{label}", key: [:clear_filter, key],
              width: [224, (@main_width - (refinements.length - 1) * 8).fdiv(refinements.length)].min + gap,
              margin_right: gap) do
              @filters.delete(key)
              request_catalog
            end
          end
        end
      end

      def refresh_search
        @screen == :home && @query.strip.empty? ? draw_window : request_catalog
      end

      def switch_search_mode(mode)
        @mode = mode
        refresh_search
      end

      def catalog_count
        return @busy ? "جارٍ البحث…" : "" if @error || !@result

        return "#{format_number(@result.data.fetch('pagination').fetch('count'))} مؤلف" if result_key == "authors"

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
          book_footer(book, "#{format_number(book.fetch('pages_count'))} صفحة · #{format_number(book.fetch('files_count'))} ملف")
        end
      end

      def search_row(hit, query: @query)
        book = hit.fetch("book")
        in_book = @dialog&.dig(:type) == :book_search
        card do
          stack(padding: 16) do
            if in_book
              row do
                para "صفحة #{format_number(hit.fetch('number'))}", width: -124, size: 16
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
          book_footer(book, "صفحة #{format_number(hit.fetch('number'))}", hit:, query:) unless in_book
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
