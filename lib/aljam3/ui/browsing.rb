# frozen_string_literal: true

module Aljam3
  module UI
    module Browsing
      def library_name(library) = Text.plain(library.fetch("name"))

      def browse_scope(key, entity)
        label = key == :library ? library_name(entity) : Text.plain(entity.fetch("name"))
        navigate(:browse, filters: { key => entity.fetch("id") }, label:)
      end

      def author_row(author)
        card do
          stack(margin: 16) do
            para text_link(Text.plain(author.fetch("name"))) { browse_scope(:author, author) }, size: 20
            para "#{author.fetch('books_count', 0)} كتاب", size: 14, stroke: muted, margin_top: 6
            action("كتب المؤلف", icon: "arrow-left", width: 120, margin_top: 12) { browse_scope(:author, author) }
          end
        end
      end

      def draw_home
        para "مكتبتك، حيث توقفت", font: HEADING_FONT, size: 28
        para "تابع قراءتك، أو ابحث عن كتابك القادم.", size: 16, stroke: muted, margin_top: 8
        search_scope_control(top: 62)
        search_form(top: 108)
        @results = stack(top: 176, width: 1.0, height: @content_height - 176, scroll: !@dialog) do
          recent = @store.recent_books(limit: 6)
          unless recent.empty?
            para "تابع القراءة", font: HEADING_FONT, size: 21, margin_bottom: 14
            reading_card(recent.first)
            if recent.length > 1
              para "قرأت مؤخرًا", font: HEADING_FONT, size: 19, margin_top: 12, margin_bottom: 12
              recent.drop(1).each { |entry| recent_reading_row(entry) }
            end
          end
          if recent.empty? && @downloaded_ids.any?
            para "جاهزة للقراءة دون اتصال", font: HEADING_FONT, size: 21, margin_bottom: 14
            @downloaded_ids.first(3).each { |id| book_row(@store.book(id)) }
          end
          para "اكتشف المكتبة", font: HEADING_FONT, size: 21, margin_top: 24, margin_bottom: 16
          @libraries.reverse.each do |library|
            stack(height: 58, margin_right: 12) do
              para text_link(library_name(library)) { browse_scope(:library, library) }, left: 130, top: 12,
                width: @main_width - 158, size: 17
              para "#{library.fetch('books_count')} كتاب", left: 12, top: 14, width: 110, size: 14, stroke: muted, align: "left"
              line 12, 57, @main_width - 24, 57, stroke: line_color
            end
          end
          if @libraries.empty?
            para "اتصل بالإنترنت لاستكشاف المكتبة، أو افتح كتبك المحمّلة.", stroke: muted, size: 15
          end
          para "التصنيفات", font: HEADING_FONT, size: 21, margin_top: 24, margin_bottom: 16
          @categories.first(6).each { |category| category_row(category) }
          action("جميع التصنيفات", width: 1.0, margin_right: 12) { navigate(:categories) }
        end
      end

      def reading_card(entry)
        book = entry.fetch("book")
        files = @store.files(book.fetch("id"))
        files = book.fetch("files", []) if files.empty?
        file = files.find { |candidate| candidate.fetch("id") == entry.fetch("file_id") }
        total = file&.fetch("pages_count")
        location = [files.length > 1 && file&.fetch("name"), "صفحة #{entry.fetch('number')}#{total ? " من #{total}" : ''}"].select { |part| part }.join(" · ")
        card do
          stack(margin: 20) do
            book_heading(book)
            para "#{location}  ·  #{availability_label(book)}", size: 14, stroke: muted, margin_top: 14
            progress(width: 1.0, margin_top: 12).fraction = entry.fetch("number").fdiv(total).clamp(0, 1) if total&.positive?
            stack(height: 60) do
              action("متابعة القراءة", icon: "book-open", width: 168, top: 20, left: @main_width - 220, variant: :solid,
                state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book) }
              unless @downloaded_ids.include?(book.fetch("id"))
                action("تنزيل للقراءة دون اتصال", icon: "download", width: 206, top: 20, variant: :ghost) { queue_download(book) }
              end
            end
          end
        end
      end

      def recent_reading_row(entry)
        book = entry.fetch("book")
        stack(height: 78, margin_right: 12) do
          para text_link(Text.plain(book.fetch("title"))[0, 80]) { open_book(book) },
            left: 140, top: 10, width: @main_width - 164, size: 16
          para "صفحة #{entry.fetch('number')} · #{availability_label(book)}", left: 140, top: 42,
            width: @main_width - 164, size: 13, stroke: muted
          action("متابعة", left: 12, top: 17, width: 104, variant: :ghost,
            state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book) }
          line 12, 77, @main_width - 24, 77, stroke: line_color
        end
      end

      def draw_categories
        para "التصنيفات", font: HEADING_FONT, size: 24
        input(@query, top: 58, width: 1.0, tooltip: "البحث في التصنيفات") do |field|
          @query = field.text
          draw_category_choices
        end
        @category_choices = stack(top: 120, width: 1.0, height: @content_height - 120, scroll: !@dialog)
        draw_category_choices
      end

      def draw_category_choices
        @category_choices.clear do
          @categories.select { |category| Text.normalize(category.fetch("name")).include?(Text.normalize(@query)) }.each { |category| category_row(category) }
        end
      end

      def category_row(category)
        stack(height: 52, margin_right: 12) do
          flow(left: 12, top: 16, width: @main_width - 48, height: 24) do
            para "#{category.fetch('books_count', 0)} كتاب", width: 100, size: 14, stroke: muted, align: "left"
            para text_link(category.fetch("name")) { browse_scope(:category, category) }, width: -100, size: 16
          end
          line 12, 51, @main_width - 24, 51, stroke: line_color
        end
      end
    end
  end
end
