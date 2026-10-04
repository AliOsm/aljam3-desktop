# frozen_string_literal: true

module Aljam3
  module UI
    module BookSearch
      def open_book_search
        @book_search = { query: @reader.fetch(:query) } unless @book_search&.dig(:book_id) == @reader.fetch(:book).fetch("id")
        @book_search[:book_id] = @reader.fetch(:book).fetch("id")
        @book_search[:busy] = false
        open_dialog(:book_search, return_focus: "بحث")
        @book_query_field.focus
      end

      def close_book_search = close_dialog

      def book_search_dialog_height
        return 264 if @book_search[:error]

        pages = @book_search[:result]&.data&.fetch("pages")
        return 152 unless pages
        return 244 if pages.empty?

        164 + [pages.length * 184, 440].min
      end

      def draw_book_search
        row(height: 40) do
          @book_query_field = input(@book_search.fetch(:query), width: -88, tooltip: "البحث في نص هذا الكتاب", placeholder: "اكتب كلمة أو عبارة…") { |field| @book_search[:query] = field.text }
          @book_query_field.finish = proc { request_book_search }
          action("بحث", width: 88, height: 40, margin_left: 12, variant: :solid) { request_book_search }
        end
        result = @book_search[:result]
        if result
          para "#{result_count(result.data)} · #{result.source == :online ? 'متصل بالجامع' : 'دون اتصال'}", top: 52, size: 14, stroke: muted
        end
        top = result ? 84 : 52
        scroll_area(top:, height: @content_height - top, scroll: true, bottom_padding: 0) do
          if @book_search[:busy]
            para "جارٍ البحث في صفحات الكتاب…", size: 15, stroke: muted
          elsif @book_search[:error]
            empty_state("تعذّر إكمال البحث", @book_search[:error], icon: "search", action_label: "إعادة المحاولة") { request_book_search }
          elsif result
            ranking_notice(result.data) { request_book_search(expand: true) }
            result.data.fetch("pages").each { |hit| search_row(hit, query: @book_search.fetch(:searched_query)) }
            if result.data.fetch("pages").empty?
              empty_state("لا توجد نتائج", "جرّب كلمات أخرى في هذا الكتاب.", icon: "search")
            end
            page = result.data.fetch("pagination").fetch("current_page")
            page_controls(page:, previous: page > 1, following: following_page(result.data)) { |number| request_book_search(page: number) }
          else
            para "اكتب كلمة أو عبارة. يمكنك البحث في كتبك المحمّلة دون اتصال أيضًا.", size: 15, stroke: muted
          end
        end
      end

      def request_book_search(page: 1, expand: false)
        query = @book_search.fetch(:query).strip
        return if query.empty?

        @editing_field = nil
        @dialog[:scroll], @dialog_results = 0, nil
        @book_search[:pool_size] = Store::Search::POOL_SIZE if @book_search[:searched_query] != query
        @book_search[:searched_query] = query
        @book_search[:pool_size] += Store::Search::POOL_SIZE if expand
        pool_size = @book_search.fetch(:pool_size)
        @store.cancel_search if @book_search[:busy]
        dialog = @dialog
        book_id = @book_search.fetch(:book_id)
        request_number = (@book_search[:request_number] || 0) + 1
        @book_search.merge!(busy: true, error: nil, result: nil, request_number:)
        render_dialog
        @network_worker.submit(-> {
          @library.search(query, book_id:, page:, pool_size:) if @dialog.equal?(dialog) && @book_search[:request_number] == request_number
        }) do |result, error|
          next unless @dialog.equal?(dialog) && @book_search[:request_number] == request_number

          @book_search.merge!(busy: false, result:, error: error && error_message(error))
          refresh_dialog
        end
      end
    end
  end
end
