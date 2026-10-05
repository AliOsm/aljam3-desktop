# frozen_string_literal: true

require_relative "../pdf_viewport"

module Aljam3
  module UI
    module ReaderPDF
      def reader_volume = [@reader.object_id, @reader.fetch(:file).fetch("id")]

      def prepare_pdf_volume
        return if @pdf_volume == reader_volume

        @pdf_volume = reader_volume
        @pdf_viewport = PDFViewport.new(count: @reader.fetch(:file).fetch("pages_count"))
        @pdf_images, @pdf_failures, @pdf_nodes = {}, {}, {}
        @reader[:image] = @reader[:pdf_error] = nil
        @pdf_scroll_pending = @pdf_render_due = @pdf_pan = nil
      end

      def reader_pdf_pane(width:, height:, top:)
        prepare_pdf_volume
        @pdf_width, @pdf_height = width, height
        @pdf_viewport.resize(width:, height:, zoom: @reader.fetch(:zoom))
        @pdf_nodes = {}
        @pdf_pane = stack(left: PAGE_MARGIN, top:, width:, height:) do
          background surface, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          @pdf_surface = stack(width: 1.0, height:, scroll: true, direction: "rtl") do
            @pdf_canvas = stack(width: 1.0, height: @pdf_viewport.total_height)
          end
        end
        @pdf_surface.on_scroll do |offset|
          @pdf_scroll_pending = offset
          start_reader_pump
        end
        offset = @reader[:pdf_anchor] ? @pdf_viewport.position(@reader[:pdf_anchor]) : @pdf_viewport.top(@reader.fetch(:number))
        @pdf_surface.scroll_top = offset
        draw_pdf_image
      end

      def remember_pdf_anchor
        return unless reader_pdf? && @pdf_surface && @pdf_volume == reader_volume

        @reader[:pdf_anchor] = @pdf_viewport.anchor(@pdf_surface.scroll_top)
      end

      def jump_pdf_page(number)
        @pdf_scroll_pending = nil
        @pdf_surface.scroll_top = @pdf_viewport.top(number)
        remember_pdf_anchor
        draw_pdf_image
      end

      def pdf_night?
        appearance = @reader.fetch(:pdf_appearance, "auto")
        appearance == "night" || (appearance == "auto" && @theme == :dark)
      end

      def change_pdf_appearance(appearance)
        @reader[:pdf_appearance] = appearance
        save_reader_options
        if @dialog&.dig(:type) == :reader_options
          @appearance_buttons.each { |value, button| button.color = value == appearance ? accent : card_color }
        end
        @pdf_nodes&.each_value { |node| node[:image]&.style(night_mode: pdf_night?) }
      end

      def change_zoom(change)
        zoom = (@reader.fetch(:zoom) + change).clamp(0.5, 3.0)
        return if zoom == @reader[:zoom]

        remember_pdf_anchor
        @reader[:zoom] = zoom
        draw_pdf_image
        update_pdf_controls
        return unless reader_pdf?

        # Show existing pixels immediately; combine a burst of zoom clicks before
        # asking PDFium for sharper pixels. Cancellation still interrupts old reads.
        invalidate_pdf_render
        @pdf_render_due = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.08
        start_reader_pump
      end

      def fit_pdf_page
        return if @reader.fetch(:zoom) == 1.0

        change_zoom(1.0 - @reader.fetch(:zoom))
        jump_pdf_page(@reader.fetch(:number)) if @pdf_surface
      end

      def update_pdf_controls
        ready = @reader[:image] && !@reader[:pdf_error]
        zoom = @reader.fetch(:zoom)
        @fit_button&.style(state: ready && zoom != 1.0 ? nil : "disabled")
        @zoom_in_button&.style(state: ready && zoom < 3.0 ? nil : "disabled")
        @zoom_out_button&.style(state: ready && zoom > 0.5 ? nil : "disabled")
      end

      def invalidate_pdf_render
        @render_number = (@render_number || 0) + 1
        @pdf_pending = nil
      end

      def render_pdf
        return unless reader_pdf? && @pdf_surface

        invalidate_pdf_render
        @pdf_failures.clear
        @pdf_refresh_page = @reader.fetch(:number)
        @pdf_render_due = nil
        draw_pdf_image
        request_pdf_page
      end

      def pdf_render_width = ((@pdf_width - 32) * @reader.fetch(:zoom) * 1.5).to_i.clamp(240, 2400)

      def request_pdf_page
        return unless reader_pdf? && @pdf_surface && !@pdf_pending && !@pdf_render_due

        wanted = @pdf_viewport.nearby(@pdf_surface.scroll_top)
        active = @reader.fetch(:number)
        number = ([active] + wanted.sort_by { |page| (page - active).abs }).uniq.find do |page|
          !@pdf_failures[page] && (@pdf_images[page]&.width != pdf_render_width || @pdf_refresh_page == page)
        end
        return unless number

        @pdf_refresh_page = nil if @pdf_refresh_page == number
        generation = @render_number
        token = @pdf_pending = [generation, number]
        book, file = @reader.values_at(:book, :file)
        width = pdf_render_width
        check = -> { raise PDF::Cancelled unless @render_number == generation && reader_pdf? }
        @render_worker.submit(-> {
          check.call
          source = @reading.pdf_source(book.fetch("id"), file)
          @pdf.render(source, page: number, width:, check:)
        }) do |rendered, error|
          next unless reader_pdf? && @pdf_pending == token && @render_number == generation

          @pdf_pending = nil
          if error
            @pdf_failures[number] = error_message(error)
          else
            @reader[:pdf_anchor] = @pdf_viewport.anchor(@pdf_surface.scroll_top, at: 0)
            @pdf_images[number] = rendered
            changed = @pdf_viewport.learn(number, width: rendered.width, height: rendered.height)
            @pdf_surface.scroll_top = @pdf_viewport.position(@reader[:pdf_anchor]) if changed
          end
          draw_pdf_image
          request_pdf_page
        end
        start_reader_pump
      end

      def start_reader_pump
        @reader_pump ||= every(1.0 / 60) { pump_reader }
      end

      def pump_reader
        unless @screen == :reader
          @pdf_scroll_pending = @pdf_render_due = @text_load_due = nil
          @reader_pump&.remove
          @reader_pump = nil
          return
        end
        if @pdf_scroll_pending && reader_pdf?
          offset, @pdf_scroll_pending = @pdf_scroll_pending, nil
          number = @pdf_viewport.active(offset)
          activate_reader_page(number, delay: true) if number != @reader[:number]
          if @pdf_pending && !@pdf_viewport.nearby(offset).include?(@pdf_pending.last)
            invalidate_pdf_render
          end
          remember_pdf_anchor
          draw_pdf_image
          @pdf_render_due = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.06
        end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        load_reader_text if @text_load_due && now >= @text_load_due
        if @pdf_render_due && now >= @pdf_render_due
          @pdf_render_due = nil
          request_pdf_page
        end
        @render_worker.drain
        @page_worker.drain
        unless @pdf_pending || @pdf_render_due || @pdf_scroll_pending || @text_load_due || @reader[:loading_text]
          @reader_pump&.remove
          @reader_pump = nil
        end
      end

      def draw_pdf_image
        return unless reader_pdf? && @pdf_surface

        anchor = @reader[:pdf_anchor]
        changed = @pdf_viewport.resize(width: @pdf_width, height: @pdf_height, zoom: @reader.fetch(:zoom))
        @pdf_surface.scroll_top = @pdf_viewport.position(anchor) if changed && anchor
        @pdf_canvas.height = @pdf_viewport.total_height if @pdf_canvas.height != @pdf_viewport.total_height
        pages = @pdf_viewport.nearby(@pdf_surface.scroll_top)
        (@pdf_nodes.keys - pages).each { |page| @pdf_nodes.delete(page).fetch(:slot).remove }
        @pdf_images.keep_if { |page, _| pages.include?(page) }
        @pdf_failures.keep_if { |page, _| pages.include?(page) }
        pages.each { |page| update_pdf_node(page) }
        number = @reader.fetch(:number)
        @reader.merge!(image: @pdf_images[number], pdf_error: @pdf_failures[number])
        @page_image = @pdf_nodes.dig(number, :image)
        update_pdf_controls
        restore_navigation_scroll
      end

      def update_pdf_node(number)
        rendered, error = @pdf_images[number], @pdf_failures[number]
        display_width, display_height = @pdf_viewport.dimensions(number)
        node = @pdf_nodes[number] ||= begin
          slot = @pdf_canvas.stack(left: 0, top: @pdf_viewport.top(number), width: 1.0, height: @pdf_viewport.page_height(number))
          slot.click { |_button, x, _y| @drag = [x, @pdf_pan || 0] unless @dialog }
          slot.motion do |x, _y|
            next unless @drag && !@dialog

            @pdf_pan = @drag[1] + x - @drag[0]
            draw_pdf_image
          end
          slot.release { @drag = nil }
          { slot: }
        end
        geometry = [@pdf_viewport.top(number), @pdf_viewport.page_height(number)]
        if node[:geometry] != geometry
          node[:geometry] = geometry
          node[:slot].style(top: geometry.first, height: geometry.last)
        end
        signature = [rendered&.path, error]
        if node[:signature] != signature
          node[:signature] = signature
          node[:image] = nil
          node[:slot].clear do
            if rendered && !error
              node[:image] = image(rendered.path, alt: "صفحة #{number} من الكتاب")
            else
              para(error || "جارٍ تحميل الصفحة #{number}…", top: 24, left: 24, width: @pdf_width - 48, size: 15, stroke: muted)
              action("إعادة تحميل الصفحة", top: 60, left: 24) { @pdf_failures.delete(number); request_pdf_page } if error
            end
          end
        end
        return unless node[:image]

        overflow = [display_width - @pdf_width + 24, 0].max / 2.0
        pan = (@pdf_pan || 0).clamp(-overflow, overflow)
        styles = { width: display_width, height: display_height, left: ((@pdf_width - display_width) / 2.0 + pan).round,
          top: PDFViewport::GAP / 2, night_mode: pdf_night? }
        if node[:styles] != styles || node[:styled_image] != node[:image]
          node[:styles], node[:styled_image] = styles, node[:image]
          node[:image].style(**styles)
        end
      end
    end
  end
end
