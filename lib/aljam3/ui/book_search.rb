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

      def draw_book_search
        row(height: 40) do
          @book_query_field = input(@book_search.fetch(:query), width: -88, tooltip: "البحث في نص هذا الكتاب", placeholder: "اكتب كلمة أو عبارة…") { |field| @book_search[:query] = field.text }
          @book_query_field.finish = proc { request_book_search }
          action("بحث", width: 88, height: 40, margin_left: 12, variant: :solid) { request_book_search }
        end
        result = @book_search[:result]
        row(top: 52, height: 28) do
          para Text.plain(@reader.fetch(:book).fetch("title")), width: result ? -230 : 1.0, size: 14, stroke: muted, wrap: "trim"
          if result
            para "#{result_count(result.data)} · #{result.source == :online ? 'متصل بالجامع' : 'دون اتصال'}", width: 230, size: 13, stroke: muted, align: "left"
          end
        end
        scroll_area(top: 90, height: @content_height - 90, scroll: true) do
          if @book_search[:busy]
            empty_state("جارٍ البحث…", "نبحث عن الكلمات في هذا الكتاب.", icon: "search")
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
            empty_state("ابحث في صفحات الكتاب", "اكتب كلمة أو عبارة. يعمل البحث أيضًا في كتبك المحمّلة دون اتصال.", icon: "search")
          end
        end
      end

      def request_book_search(page: 1, expand: false)
        query = @book_search.fetch(:query).strip
        return if query.empty?

        @editing_field = nil
        @book_search[:pool_size] = Store::Search::POOL_SIZE if @book_search[:searched_query] != query
        @book_search[:searched_query] = query
        @book_search[:pool_size] += Store::Search::POOL_SIZE if expand
        pool_size = @book_search.fetch(:pool_size)
        @store.cancel_search if @book_search[:busy]
        dialog = @dialog
        book_id = @book_search.fetch(:book_id)
        request_number = (@book_search[:request_number] || 0) + 1
        @book_search.merge!(busy: true, error: nil, result: nil, request_number:)
        draw_window
        @network_worker.submit(-> {
          @library.search(query, book_id:, page:, pool_size:) if @dialog.equal?(dialog) && @book_search[:request_number] == request_number
        }) do |result, error|
          next unless @dialog.equal?(dialog) && @book_search[:request_number] == request_number

          @book_search.merge!(busy: false, result:, error: error && error_message(error))
          refresh_window
        end
      end
    end
  end
end
