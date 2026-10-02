# frozen_string_literal: true

module Aljam3
  module UI
    module Components
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
