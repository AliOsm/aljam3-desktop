# frozen_string_literal: true

require_relative "../formatting"

module Aljam3
  module UI
    PAGE_MARGIN = 24
    PAGE_TOP = 76
    COLUMN_GAP = 24
    SCROLL_GUTTER = 16
    STATUS_HEIGHT = 32
    READER_GAP = 16

    module Components
      def format_number(value) = Formatting.number(value)

      def schedule_once(seconds, &block)
        task = timer(seconds) do
          task.remove
          block.call
        end
      end

      def row(**styles, &block)
        flow(width: 1.0, height: 36, direction: "rtl", valign: "center", **styles, &block)
      end

      def scroll_area(bottom_padding: 16, **styles, &block)
        area = stack(left: -SCROLL_GUTTER, width: @main_width + SCROLL_GUTTER, direction: "rtl", scroll: true, **styles) do
          stack(margin: [SCROLL_GUTTER, 0, 0, bottom_padding], &block)
        end
        if @drawing_dialog
          @dialog_results = area
          area.scroll_top = @dialog.fetch(:scroll, 0)
        end
        area
      end

      def grid(items, columns:, gap: COLUMN_GAP, row_gap: 16)
        cell_width = (@main_width - gap * (columns - 1)).fdiv(columns)
        items.each_slice(columns) do |items_in_row|
          flow(width: 1.0, direction: "rtl", valign: "stretch", align_heights: true, margin_bottom: row_gap) do
            items_in_row.each_with_index do |item, index|
              gutter = index < columns - 1 ? gap : 0
              yield item, { width: cell_width + gutter, margin_right: gutter, margin_bottom: 0 }
            end
          end
        end
      end

      def separator(**styles)
        stack(height: 1 + styles.fetch(:margin_top, 0) + styles.fetch(:margin_bottom, 0), **styles) { background line_color }
      end

      def section_heading(title, action: nil, &block)
        row(height: 40, margin_bottom: 12) do
          para title, width: action ? -132 : 1.0, font: HEADING_FONT, size: 20
          para text_link(action, &block), width: 132, size: 14, align: "left" if action
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

        stack(height: 52, margin_top: 8) do
          row(left: (@main_width - 324) / 2, top: 8, width: 324) do
            action("السابق", icon: "arrow-right", width: 100, state: previous ? nil : "disabled") { change.call(page - 1) }
            para "صفحة #{format_number(page)}", width: 124, size: 14, stroke: muted, align: "center"
            action("التالي", icon: "arrow-left", width: 100, state: following ? nil : "disabled") { change.call(page + 1) }
          end
        end
      end

      def result_count(data)
        pagination = data.fetch("pagination")
        count = pagination.fetch("count")
        pagination["count_is_exact"] == false ? "أكثر من #{format_number(count)} نتيجة" : "#{format_number(count)} نتيجة"
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
            para "مرتبة من أول #{format_number(ranking.fetch('candidates'))} صفحة مطابقة", width: -140, size: 14
            action("البحث في المزيد", width: 140, &expand)
          end
          para "توسيع البحث يضيف صفحات مطابقة وقد يغيّر ترتيب النتائج.", size: 13, stroke: muted, margin_top: 8
        end
      end

      def action(label, icon: nil, variant: :outline, selected: false, key: nil, **styles, &block)
        color = selected ? accent : { solid: primary, outline: card_color, ghost: "transparent" }.fetch(variant)
        styles[:icon] = asset_path("icons", icon, theme: variant == :solid && !selected ? :dark : @theme) if icon
        styles[:height] ||= 36 + styles.fetch(:margin_top, 0) + styles.fetch(:margin_bottom, 0)
        styles[:icon_pos] ||= %w[arrow-left chevron-down].include?(icon) ? "left" : "right"
        key ||= styles[:tooltip] || label
        control = button(label, variant: variant.to_s, color:, text_color: variant == :solid && !selected ? "#ffffff" : ink,
          border_color: line_color, disabled_color: card_color, stroke: primary, focus_inset: true, hover_amount: 0.0, **styles) do |clicked|
          @editing_field = nil
          @last_action_key = key
          @last_action_rect = Shoes::DisplayService.layout_cache[clicked.linkable_id]&.first(4)
          block&.call(clicked)
        end
        animate_hover(control)
        feedback = @drawing_notification || @drawing_dialog
        control.focus_changed = proc { |focused_control, focused| @last_content_focus = focused_control if focused && !feedback }
        (@action_views ||= {})[key] = control
        control
      end

      def input(text = "", **styles, &block)
        field = edit_line(text, align: "right", disabled_color: card_color, placeholder_color: muted, focus_inset: true, focus_color: primary, **styles) do |control|
          block&.call(control)
        end
        dialog = @drawing_dialog
        field.focus_changed = proc do |control, focused|
          @editing_field = focused ? control : nil if focused || @editing_field == control
          @last_content_focus = control if focused && !dialog
        end
        field
      end

      def text_link(text, **styles, &block)
        link(text, **styles) { @editing_field = nil; block.call }
      end

      def icon_button(icon, label, **styles, &block)
        action("", icon:, tooltip: label, width: 36, variant: :ghost, **styles, &block)
      end

      def dropdown(choices, selected:, key:, **styles, &select)
        action(choices.fetch(selected), icon: "chevron-down", key:, **styles) do
          open_dialog(:select, nested: !!@dialog, choices: choices.map { |value, label| [label, value] }, selected:, selection: select)
        end
      end

      def tabs(choices, selected:, width:, widths: {}, **position, &select)
        row(width:, **position) do
          choices.each_with_index do |(value, label), index|
            gap = index < choices.length - 1 ? 8 : 0
            action(label, selected: value == selected,
              width: widths.fetch(value, (width - (choices.length - 1) * 8).fdiv(choices.length)) + gap,
              margin_right: gap, height: 36) { select.call(value) }
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
        stack(padding_top: 8, padding_bottom: 8) do
          row(height: 32) do
            image asset_path("icons", icon), width: 32, height: 24, margin_right: 8
            para heading, width: -32, font: HEADING_FONT, size: 20
          end
          para description, size: 15, stroke: muted, margin_top: 8
          row(margin_top: 12, height: 48) { action(action_label, width: 160, variant: :solid, &on_action) } if action_label
        end
      end
    end
  end
end
