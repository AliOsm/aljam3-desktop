# frozen_string_literal: true

module Aljam3
  module UI
    module BookSearch
      def open_book_search
        @book_search = { query: "" } unless @book_search&.dig(:book_id) == @reader.fetch(:book).fetch("id")
        @book_search[:book_id] = @reader.fetch(:book).fetch("id")
        @book_search[:busy] = false
        @screen = :book_search
        @render_number += 1
        draw_window
        @book_query_field.focus
      end

      def close_book_search
        @request_number += 1
        @book_search[:busy] = false
        @screen = :reader
        draw_window
        render_pdf if reader_pdf?
      end

      def draw_book_search
        action("رجوع للكتاب", icon: "arrow-right", left: 0, top: 0, width: 132, variant: :ghost) { close_book_search }
        para "بحث في الكتاب", left: 144, width: @main_width - 144, font: HEADING_FONT, size: 24
        para Text.plain(@reader.fetch(:book).fetch("title")), top: 48, size: 16, stroke: MUTED
        flow(top: 82, width: 1.0, height: 62) do
          action("بحث", width: 88, height: 61, margin_right: 12, margin_top: 21, variant: :solid) { request_book_search }
          stack(width: -88) do
            para "البحث في نص هذا الكتاب", size: 13, stroke: MUTED, margin_bottom: 5
            @book_query_field = edit_line(@book_search.fetch(:query), width: 1.0, align: "right") { |field| @book_search[:query] = field.text }
            @book_query_field.finish = proc { request_book_search }
          end
        end
        result = @book_search[:result]
        para "#{result.data.fetch('pagination').fetch('count')} نتيجة في هذا الكتاب", top: 160, size: 14, stroke: MUTED if result && !@book_search[:busy]
        stack(top: 194, width: 1.0, height: @content_height - 244, scroll: true) do
          if @book_search[:busy]
            empty_state("جارٍ البحث…", "نبحث عن الكلمات في هذا الكتاب.", icon: "search")
          elsif @book_search[:error]
            empty_state("تعذّر إكمال البحث", @book_search[:error], icon: "search", action_label: "إعادة المحاولة") { request_book_search }
          elsif result
            if result.data.fetch("pages").empty?
              empty_state("لا توجد نتائج", "جرّب كلمات أخرى في هذا الكتاب.", icon: "search")
            else
              result.data.fetch("pages").each { |hit| search_row(hit, query: @book_search.fetch(:query)) }
            end
          else
            empty_state("ابحث في صفحات الكتاب", "اكتب كلمة أو عبارة. يعمل البحث أيضًا دون اتصال.", icon: "search")
          end
        end
        draw_pagination(result) { |page| request_book_search(page:) } if result && !@book_search[:busy]
      end

      def request_book_search(page: 1)
        query = @book_search.fetch(:query).strip
        if query.empty?
          @request_number += 1
          @book_search.merge!(result: nil, busy: false, error: nil)
          draw_window
          return
        end

        @request_number += 1
        request_number = @request_number
        book_id = @book_search.fetch(:book_id)
        @book_search.merge!(busy: true, error: nil)
        draw_window
        @network_worker.submit(-> { @library.search(query, book_id:, page:) }) do |result, error|
          next unless @screen == :book_search && @request_number == request_number

          @book_search.merge!(busy: false, result:, error: error && error_message(error))
          draw_window
        end
      end
    end
  end
end
