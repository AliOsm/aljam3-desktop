# frozen_string_literal: true

module Aljam3
  module UI
    module Components
      def page_controls(page:, previous:, following:, &change)
        return unless previous || following

        flow(height: 48, margin_top: 12) do
          action("التالي", width: 100, state: following ? nil : "disabled", margin_right: 12) { change.call(page + 1) }
          para "صفحة #{page}", width: 100, size: 14, stroke: muted, margin_top: 10
          action("السابق", width: 100, state: previous ? nil : "disabled") { change.call(page - 1) }
        end
      end

      def result_count(data)
        pagination = data.fetch("pagination")
        count = pagination.fetch("count")
        pagination["count_is_exact"] == false ? "أكثر من #{count} نتيجة" : "#{count} نتيجة"
      end

      def following_page(data)
        pagination = data.fetch("pagination")
        return pagination["next_page"] if pagination.key?("next_page")

        current = pagination.fetch("current_page")
        current + 1 if current < pagination.fetch("total_pages")
      end

      def action(label, icon: nil, variant: :outline, selected: false, **styles, &block)
        color = selected ? accent : { solid: primary, outline: card_color, ghost: "transparent" }.fetch(variant)
        styles[:icon] = asset_path("icons", icon, theme: variant == :solid && !selected ? :dark : @theme) if icon
        styles[:state] = "disabled" if @dialog && !@drawing_dialog
        # Shoes includes margins inside an explicit height.
        styles[:height] ||= 36 + styles.fetch(:margin_top, 0) + styles.fetch(:margin_bottom, 0)
        button(label, variant: variant.to_s, color:, text_color: variant == :solid && !selected ? "#ffffff" : ink,
          border_color: line_color, disabled_color: card_color, stroke: primary, icon_pos: "right", **styles, &block)
      end

      def input(text = "", **styles, &block)
        styles[:state] = "disabled" if @dialog && !@drawing_dialog
        edit_line(text, align: "right", disabled_color: card_color, **styles, &block)
      end

      def text_link(text, **styles, &block)
        return span(text, **styles) if @dialog && !@drawing_dialog

        link(text, **styles, &block)
      end

      def icon_button(icon, label, **styles, &block)
        action("", icon:, tooltip: label, width: 36, variant: :ghost, **styles, &block)
      end

      def tabs(choices, selected:, width:, **position, &select)
        flow(width:, height: 38, **position) do
          background surface, curve: 6
          choices.each do |value, label|
            action(label, variant: :ghost, selected: value == selected,
              width: width / choices.length, height: 38) { select.call(value) }
          end
        end
      end

      def highlighted(text, query)
        terms = Text.normalize(query).split
        text.split(/(\s+)/).map do |word|
          terms.any? { |term| Text.normalize(word).include?(term) } ? span(word, fill: accent, stroke: primary) : word
        end
      end

      def status_note(text, width:, **position)
        stack(width:, height: 28, **position) do
          background surface, curve: 5
          para text, size: 14, stroke: muted, align: "center", margin_top: 4
        end
      end

      def empty_state(heading, description, icon: "book-open", action_label: nil, &on_action)
        stack(margin: [32, 42, 32, 32]) do
          stack(height: 46, width: 1.0) do
            image asset_path("icons", icon), left: @main_width - 92, width: 28, height: 28
          end
          para heading, font: HEADING_FONT, size: 22
          para description, size: 16, stroke: muted, margin_top: 12
          if action_label
            stack(height: 56) do
              action(action_label, left: @main_width - 224, top: 20, width: 160, &on_action)
            end
          end
        end
      end
    end
  end
end
