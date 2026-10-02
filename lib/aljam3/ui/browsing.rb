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
          stack(padding: 16) do
            para text_link(Text.plain(author.fetch("name"))) { browse_scope(:author, author) }, size: 20
            row(margin_top: 12, height: 48) do
              para "#{author.fetch('books_count', 0)} كتاب", width: -132, size: 14, stroke: muted
              action("كتب المؤلف", icon: "arrow-left", width: 132) { browse_scope(:author, author) }
            end
          end
        end
      end

      def draw_home
        recent = @store.recent_books(limit: 4)
        para recent.empty? ? "المكتبة بين يديك" : "مكتبتك، حيث توقفت", font: HEADING_FONT, size: 26
        para "ابحث في الكتب، وتابع القراءة، واحتفظ بما تحتاجه دون اتصال.", size: 16, stroke: muted, margin_top: 8
        search_scope_control(top: 64)
        search_form(top: 112)
        @results = scroll_area(top: 180, height: @content_height - 180) do
          unless recent.empty?
            columns = @main_width >= 920 && recent.size > 1
            flow(direction: "rtl") do
              stack(width: columns ? 0.52 : 1.0, padding_left: columns ? 24 : 0) do
                section_heading("تابع القراءة")
                reading_card(recent.first)
              end
              if recent.size > 1
                stack(width: columns ? 0.48 : 1.0) do
                  section_heading("قرأت مؤخرًا")
                  recent.drop(1).each { |entry| recent_reading_row(entry) }
                end
              end
            end
          end
          section_heading("اكتشف المكتبة", action: "جميع الكتب") { navigate(:browse) }
          if @libraries.empty?
            para "اتصل بالإنترنت لاستكشاف المكتبة، أو افتح كتبك المحمّلة.", stroke: muted, size: 15, margin_bottom: 20
          else
            columns = @main_width >= 940 ? 3 : 2
            flow(direction: "rtl") do
              @libraries.each do |library|
                stack(width: 1.0 / columns, padding_left: 12) do
                  card do
                    stack(padding: 16) do
                      para text_link(library_name(library)) { browse_scope(:library, library) }, size: 18
                      row(margin_top: 12, height: 48) do
                        para "#{library.fetch('books_count')} كتاب", width: -36, size: 14, stroke: muted
                        icon_button("arrow-left", "استكشاف #{library_name(library)}") { browse_scope(:library, library) }
                      end
                    end
                  end
                end
              end
            end
          end
          section_heading("التصنيفات", action: "جميع التصنيفات") { navigate(:categories) }
          category_grid(@categories.first(6))
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
          stack(padding: 20) do
            book_heading(book)
            para location, size: 14, stroke: muted, margin_top: 16
            if total&.positive?
              progress(width: 1.0, height: 24, margin_top: 16).fraction = entry.fetch("number").fdiv(total).clamp(0, 1)
            end
            row(height: 60, margin_top: 24) do
              action("متابعة القراءة", icon: "book-open", width: 164, variant: :solid,
                state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book) }
              para availability_label(book), width: -164, size: 13, stroke: muted, align: "left"
            end
          end
        end
      end

      def recent_reading_row(entry)
        book = entry.fetch("book")
        row(height: 82) do
          stack(width: -44) do
            para text_link(Text.plain(book.fetch("title"))) { open_book(book) }, size: 16, wrap: "trim"
            para "صفحة #{entry.fetch('number')} · #{availability_label(book)}", size: 13, stroke: muted, margin_top: 6
          end
          icon_button("arrow-left", "متابعة #{Text.plain(book.fetch('title'))}", width: 44,
            state: offline_unavailable?(book) ? "disabled" : nil) { open_book(book) }
        end
        separator
      end

      def draw_categories
        para "التصنيفات", font: HEADING_FONT, size: 24
        para "اختر مجالًا لاستكشاف كتبه، أو ابحث عن تصنيف.", size: 15, stroke: muted, margin_top: 8
        input(@query, top: 72, width: 1.0, height: 44, placeholder: "اسم التصنيف…", tooltip: "البحث في التصنيفات") do |field|
          @query = field.text
          draw_category_choices
        end
        @category_choices = stack(top: 140, width: 1.0, height: @content_height - 140, scroll: !@dialog, direction: "rtl")
        draw_category_choices
      end

      def draw_category_choices
        @category_choices.clear do
          stack(padding_left: 14) do
            categories = @categories.select { |category| Text.normalize(category.fetch("name")).include?(Text.normalize(@query)) }
            if categories.empty?
              empty_state("لا توجد تصنيفات مطابقة", "جرّب اسمًا آخر أو امسح البحث.", icon: "search")
            else
              category_grid(categories)
            end
          end
        end
      end

      def category_grid(categories)
        flow(direction: "rtl") do
          categories.each do |category|
            stack(width: 0.5, padding_left: 16) do
              row(height: 60) do
                para text_link(category.fetch("name")) { browse_scope(:category, category) }, width: -100, size: 16
                para "#{category.fetch('books_count', 0)} كتاب", width: 100, size: 13, stroke: muted, align: "left"
              end
              separator
            end
          end
        end
      end
    end
  end
end
