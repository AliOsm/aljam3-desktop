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
        stack(left: (@main_width - 480) / 2, top: 0, width: 480, height: 120) do
          image asset_path("brand", "aljam3"), left: 360, top: 4, width: 112, height: 88, alt: "الجامع"
          para "مكان واحد", left: 0, top: 10, width: 328, font: HEADING_FONT, size: 30
          para "كتب التراث الإسلامي، نصًّا وصورةً.", left: 0, top: 60, width: 328, size: 20, stroke: muted
        end
        search_form(top: 122)
        flow(left: @main_width - 412, top: 176, width: 412, height: 36) do
          ["إنما الأعمال بالنيات", "ذلك الكتاب لا ريب فيه"].each do |example|
            action(example, width: 206, margin_left: 8, variant: :ghost, selected: true) { @query = example; request_catalog }
          end
        end
        stack(top: 242, width: 1.0, height: @content_height - 242, scroll: !@dialog) do
          para "تصفح المكتبات", font: HEADING_FONT, size: 21, margin_bottom: 16
          flow(width: 1.0, height: 104) do
            @libraries.reverse.each do |library|
              stack(width: 1.0 / [@libraries.length, 1].max, height: 104, margin_right: 12) do
                background card_color, curve: CARD_RADIUS
                border line_color, curve: CARD_RADIUS
                stack(margin: 16) do
                  para text_link(library_name(library)) { browse_scope(:library, library) }, size: 17
                  para "#{library.fetch('books_count')} كتاب", size: 14, stroke: muted, margin_top: 12
                end
              end
            end
          end
          if @libraries.empty?
            para "اتصل بالإنترنت لاستكشاف المكتبة، أو افتح كتبك المحمّلة.", stroke: muted, size: 15
          end
          para "التصنيفات", font: HEADING_FONT, size: 21, margin_top: 24, margin_bottom: 16
          @categories.first(12).each { |category| category_row(category) }
          action("جميع التصنيفات", width: 1.0, margin_right: 12) { navigate(:categories) }
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
