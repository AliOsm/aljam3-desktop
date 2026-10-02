# frozen_string_literal: true

module Aljam3
  module UI
    module Components
      def row(**styles, &block)
        flow(width: 1.0, height: 36, direction: "rtl", valign: "center", **styles, &block)
      end

      def scroll_area(**styles, &block)
        stack(width: 1.0, direction: "rtl", scroll: !@dialog, **styles) do
          stack(margin: [14, 0, 0, 16], &block)
        end
      end

      def separator(**styles)
        stack(height: 1, **styles) { background line_color }
      end

      def section_heading(title, action: nil, &block)
        row(height: 40, margin_bottom: 12) do
          para title, width: action ? -132 : 1.0, font: HEADING_FONT, size: 20
          self.action(action, width: 132, variant: :ghost, &block) if action
        end
      end

      def card(**styles, &block)
        stack(margin_bottom: 16, **styles) do
          background card_color, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          instance_exec(&block)
        end
      end

      def page_controls(page:, previous:, following:, &change)
        return unless previous || following

        row(height: 52, margin_top: 8) do
          action("السابق", icon: "arrow-right", width: 100, state: previous ? nil : "disabled") { change.call(page - 1) }
          para "صفحة #{page}", width: 100, size: 14, stroke: muted, align: "center"
          action("التالي", icon: "arrow-left", width: 100, state: following ? nil : "disabled") { change.call(page + 1) }
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

      def ranking_notice(data, &expand)
        ranking = data["ranking"]
        return unless ranking && ranking["has_more"]

        stack(padding: 16, margin_bottom: 16) do
          background surface, curve: CARD_RADIUS
          row do
            para "مرتبة من أول #{ranking.fetch('candidates')} صفحة مطابقة", width: -140, size: 14
            action("البحث في المزيد", width: 140, &expand)
          end
          para "توسيع البحث يضيف صفحات مطابقة وقد يغيّر ترتيب النتائج.", size: 13, stroke: muted, margin_top: 8
        end
      end

      def action(label, icon: nil, variant: :outline, selected: false, key: nil, **styles, &block)
        color = selected ? accent : { solid: primary, outline: card_color, ghost: "transparent" }.fetch(variant)
        styles[:icon] = asset_path("icons", icon, theme: variant == :solid && !selected ? :dark : @theme) if icon
        styles[:state] = "disabled" if @dialog && !@drawing_dialog
        styles[:height] ||= 36 + styles.fetch(:margin_top, 0) + styles.fetch(:margin_bottom, 0)
        key ||= styles[:tooltip] || label
        control = button(label, variant: variant.to_s, color:, text_color: variant == :solid && !selected ? "#ffffff" : ink,
          border_color: line_color, disabled_color: @dialog && !@drawing_dialog ? rgb(0, 0, 0, 0) : card_color, stroke: primary, icon_pos: "right", **styles) do |clicked|
          @editing_field = nil
          @last_action_key = key
          @last_action_rect = Shoes::DisplayService.layout_cache[clicked.linkable_id]&.first(4)
          block&.call(clicked)
        end
        (@action_views ||= {})[key] = control
        control
      end

      def input(text = "", **styles, &block)
        styles[:state] = "disabled" if @dialog && !@drawing_dialog
        field = edit_line(text, align: "right", disabled_color: card_color, placeholder_color: muted, **styles) do |control|
          block&.call(control)
        end
        field.focus_changed = proc do |control, focused|
          @editing_field = focused ? control : nil if focused || @editing_field == control
        end
        field
      end

      def text_link(text, **styles, &block)
        return span(text, **styles) if @dialog && !@drawing_dialog

        link(text, **styles) { @editing_field = nil; block.call }
      end

      def icon_button(icon, label, **styles, &block)
        action("", icon:, tooltip: label, width: 36, variant: :ghost, **styles, &block)
      end

      def tabs(choices, selected:, width:, widths: {}, **position, &select)
        row(width:, **position) do
          background surface, curve: CARD_RADIUS
          choices.each do |value, label|
            action(label, variant: :ghost, selected: value == selected,
              width: widths.fetch(value, width / choices.length), height: 36) { select.call(value) }
          end
        end
      end

      def highlighted(text, query)
        text.split(/(\s+)/).map do |word|
          Text.match_ranges(word, query).any? ? span(word, fill: accent, stroke: primary) : word
        end
      end

      def status_note(text, width:, **position)
        stack(width:, height: 28, **position) do
          background surface, curve: CARD_RADIUS
          para text, size: 14, stroke: muted, align: "center", margin_top: 4
        end
      end

      def empty_state(heading, description, icon: "book-open", action_label: nil, &on_action)
        stack(padding: 24, margin_top: 16) do
          row(height: 40) do
            image asset_path("icons", icon), width: 24, height: 24, margin_right: 12
            para heading, width: -40, font: HEADING_FONT, size: 21
          end
          para description, size: 16, stroke: muted, margin_top: 12
          row(margin_top: 20, height: 56) { action(action_label, width: 160, variant: :solid, &on_action) } if action_label
        end
      end
    end
  end
end
