# frozen_string_literal: true

require_relative "../pdf_viewport"

module Aljam3
  module UI
    module ReaderPDF
      PDF_MEMORY_BYTES = 32 * 1024 * 1024
      PDF_MEMORY_PAGES = 32

      def reader_volume = [@reader.object_id, @reader.fetch(:file).fetch("id")]

      def prepare_pdf_volume
        return if @pdf_volume == reader_volume

        release_pdf_images
        @pdf_volume = reader_volume
        @pdf_viewport = PDFViewport.new(count: @reader.fetch(:file).fetch("pages_count"))
        @pdf_images, @pdf_failures, @pdf_nodes = {}, {}, {}
        @reader[:image] = @reader[:pdf_error] = nil
        @pdf_scroll_pending = @pdf_render_due = @pdf_pan = nil
        @pdf_direction, @pdf_scroll_speed = 1, 0
        @pdf_last_scroll = @pdf_loading_due = nil
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

        @pdf_pan = 0
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
        @pdf_render_due = nil
        draw_pdf_image
        request_pdf_page
      end

      # Size pixels for the fitted page rather than for the entire pane. Bucket
      # widths to avoid re-rendering for tiny geometry or window-size changes.
      def pdf_render_width(number = @reader.fetch(:number))
        ((@pdf_viewport.dimensions(number).first * 1.5 / 64).ceil * 64).clamp(240, 2400)
      end

      def pdf_wanted_pages
        visible = @pdf_viewport.visible(@pdf_surface.scroll_top)
        ahead = (@pdf_scroll_speed.to_f.abs * 0.35 / @pdf_viewport.page_height(visible.first)).ceil.clamp(3, 6)
        first, last = visible.first, visible.last
        forward = @pdf_direction.to_i >= 0 ? (last + 1..last + ahead).to_a : (first - ahead...first).to_a.reverse
        behind = @pdf_direction.to_i >= 0 ? [first - 1] : [last + 1]
        ([@reader.fetch(:number)] + visible + forward + behind).uniq.select { |page| (1..@pdf_viewport.count).cover?(page) }
      end

      def pdf_image_bytes = (@pdf_images || {}).values.sum { |item| item.width * item.height * 4 }

      def release_pdf_image(rendered)
        return unless rendered&.path&.start_with?("memory:")

        Shoes::DisplayService.display_service.release_bitmap(rendered.path)
      end

      def release_pdf_images
        @pdf_images&.each_value { |rendered| release_pdf_image(rendered) }
        @pdf_images = {}
      end

      def cache_pdf_image(number, rendered)
        previous = @pdf_images.delete(number)
        release_pdf_image(previous) if previous && previous.path != rendered.path
        @pdf_images[number] = rendered
        Shoes::DisplayService.display_service.cache_bitmap(rendered.path, width: rendered.width, height: rendered.height, pixels: rendered.pixels)
        trim_pdf_images
      end

      def trim_pdf_images
        visible = @pdf_viewport.visible(@pdf_surface.scroll_top)
        # Hash insertion order is the LRU. Touch visible pages even on cache hits.
        visible.each { |page| @pdf_images[page] = @pdf_images.delete(page) if @pdf_images.key?(page) }
        while @pdf_images.size > PDF_MEMORY_PAGES || pdf_image_bytes > PDF_MEMORY_BYTES
          page = @pdf_images.keys.find { |key| !visible.include?(key) }
          break unless page # A visible high-zoom page may alone exceed the budget.

          release_pdf_image(@pdf_images.delete(page))
        end
      end

      def request_pdf_page
        return unless reader_pdf? && @pdf_surface && !@pdf_pending && !@pdf_render_due

        visible = @pdf_viewport.visible(@pdf_surface.scroll_top)
        visible_bytes = visible.sum { |page| (item = @pdf_images[page]) ? item.width * item.height * 4 : 0 }
        remaining_bytes = PDF_MEMORY_BYTES - visible_bytes
        wanted = pdf_wanted_pages.reject do |page|
          next true if @pdf_failures[page]
          next false if visible.include?(page)

          # Reserve the whole prefetch set, not just one page's headroom. Otherwise
          # near-budget pages evict one another and are rendered repeatedly.
          item = @pdf_images[page]
          width = [pdf_render_width(page), 480].min
          bytes = item ? item.width * item.height * 4 : width * (width * @pdf_viewport.ratio(page)).ceil * 4
          next true if bytes > remaining_bytes

          remaining_bytes -= bytes
          false
        end
        # Supply visible pixels first. During motion favor previews ahead; once
        # stationary sharpen the visible page before doing more network reads.
        missing = wanted.select { |page| !@pdf_images[page] }
        sharp = wanted.select { |page| visible.include?(page) && @pdf_images[page] && @pdf_images[page].width < pdf_render_width(page) }
        moving = @pdf_last_scroll && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @pdf_last_scroll.last < 0.08
        choices = missing.select { |page| visible.include?(page) }.map { |page| [page, true] }
        ahead = missing.reject { |page| visible.include?(page) }.map { |page| [page, true] }
        detail = sharp.map { |page| [page, false] }
        number, preview = (choices + (moving ? ahead + detail : detail + ahead)).first
        return unless number

        generation = @render_number
        token = @pdf_pending = [generation, number]
        book, file = @reader.values_at(:book, :file)
        width = preview ? [pdf_render_width(number), 480].min : pdf_render_width(number)
        check = -> { raise PDF::Cancelled unless @render_number == generation && reader_pdf? }
        @render_worker.submit(-> {
          check.call
          source = @reading.pdf_source(book.fetch("id"), file)
          @pdf.render_bitmap(source, page: number, width:, check:)
        }) do |rendered, error|
          next unless reader_pdf? && @pdf_pending == token && @render_number == generation

          @pdf_pending = nil
          if error
            @pdf_failures[number] = error_message(error)
          else
            @reader[:pdf_anchor] = @pdf_viewport.anchor(@pdf_surface.scroll_top, at: 0)
            cache_pdf_image(number, rendered)
            changed = @pdf_viewport.learn(number, width: rendered.width, height: rendered.height)
            if changed
              offset = @pdf_viewport.position(@reader[:pdf_anchor])
              # Learning a page's ratio often changes its width only. Sending an
              # unnecessary absolute scroll would overwrite newer wheel input.
              @pdf_surface.scroll_top = offset if (offset - @pdf_surface.scroll_top).abs >= 1
            end
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
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @pdf_last_scroll
            delta = offset - @pdf_last_scroll.first
            @pdf_direction = delta <=> 0 unless delta.zero?
            @pdf_scroll_speed = delta / [now - @pdf_last_scroll.last, 0.001].max
          end
          @pdf_last_scroll = [offset, now]
          number = @pdf_viewport.active(offset)
          activate_reader_page(number, delay: true) if number != @reader[:number]
          visible = @pdf_viewport.visible(offset)
          missing = visible.any? { |page| !@pdf_images[page] && !@pdf_failures[page] }
          if @pdf_pending && (!pdf_wanted_pages.include?(@pdf_pending.last) || (missing && !visible.include?(@pdf_pending.last)))
            invalidate_pdf_render
          end
          remember_pdf_anchor
          draw_pdf_image
          request_pdf_page
        end
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        load_reader_text if @text_load_due && now >= @text_load_due
        if @pdf_render_due && now >= @pdf_render_due
          @pdf_render_due = nil
          request_pdf_page
        end
        if @pdf_loading_due && now >= @pdf_loading_due
          @pdf_loading_due = nil
          draw_pdf_image
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
        trim_pdf_images
        wanted = pdf_wanted_pages
        @pdf_failures.keep_if { |page, _| wanted.include?(page) }
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
          slot.click { |button, x, _y| @drag = [x, @pdf_pan || 0] if button == 1 && !@dialog }
          slot.motion do |x, _y|
            @drag = nil unless mouse.first == 1
            next unless @drag && !@dialog

            @pdf_pan = @drag[1] + x - @drag[0]
            draw_pdf_image
          end
          slot.release { @drag = nil }
          { slot:, loading_since: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end
        geometry = [@pdf_viewport.top(number), @pdf_viewport.page_height(number)]
        if node[:geometry] != geometry
          node[:geometry] = geometry
          node[:slot].style(top: geometry.first, height: geometry.last)
        end
        waiting = !rendered && !error
        show_loading = waiting && Process.clock_gettime(Process::CLOCK_MONOTONIC) - node[:loading_since] >= 0.6
        @pdf_loading_due ||= node[:loading_since] + 0.6 if waiting && !show_loading
        signature = [rendered&.path, error, show_loading]
        if node[:signature] != signature
          node[:signature] = signature
          node[:image] = nil
          node[:slot].clear do
            if rendered && !error
              node[:image] = image(rendered.path, alt: "صفحة #{number} من الكتاب")
            else
              stack(left: (@pdf_width - display_width) / 2, top: PDFViewport::GAP / 2, width: display_width, height: display_height) do
                background(pdf_night? ? "#1e1b1a" : "#fffdf8")
              end
              para(error || "جارٍ تحميل الصفحة #{number}…", top: 24, left: 24, width: @pdf_width - 48, size: 15, stroke: muted) if error || show_loading
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
