# frozen_string_literal: true

# Drive the native input protocol, then inspect the rendered page's window box.
# Shared by source, relocated packages, and real (invisible) OS window checks.
module PDFPinchVerification
  def pinch_gestures(offline: false)
    @app.fit_pdf_page
    @app.turn_page(offline ? 18 : 7)
    settle
    rect = @automation.rect_of!(surface.linkable_id)
    x, y = rect.x + rect.w * 0.46, rect.y + rect.h * 0.42
    page = get(:reader)[:number]
    original = @automation.rect_of!(get(:page_image).linkable_id)
    fx, fy = (x - original.x) / original.w, (y - original.y) / original.h
    image, path = get(:page_image), get(:page_image).url
    @automation.pinch(1.0, phase: :started, x:, y:)
    errors = []
    24.times do
      @automation.pinch(1.009, x:, y:)
      actual = @automation.rect_of!(get(:pdf_nodes).fetch(page).fetch(:image).linkable_id)
      errors << [(actual.x + actual.w * fx - x).abs, (actual.y + actual.h * fy - y).abs].max
    end
    check("#{offline ? 'offline' : 'online'} pinch keeps the document point beneath the pointer", errors.max <= 1.1)
    check("pinch scales the cached image immediately", get(:page_image).equal?(image) && image.url == path && image.width > original.w)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    settle
    check("#{offline ? 'offline' : 'online'} pinch sharpens after fingers lift", get(:reader).fetch(:image).width >= @app.pdf_render_width)
    if offline
      @app.fit_pdf_page
      settle
      return
    end
    shot("pinch-zoom")

    @automation.pinch(1.0, phase: :started, x:, y:)
    @automation.pinch(20, x:, y:)
    check("pinch stops at 300% and updates the toolbar", get(:reader)[:zoom] == 3.0 && get(:zoom_in_button).state == "disabled")
    @automation.pinch(0.9, x:, y:)
    check("reversing at maximum zoom responds immediately", (get(:reader)[:zoom] - 2.7).abs < 0.00001 && get(:zoom_in_button).state.nil?)
    @automation.pinch(0.01, x:, y:)
    check("pinch stops at 50% and updates the toolbar", get(:reader)[:zoom] == 0.5 && get(:zoom_out_button).state == "disabled")
    @automation.pinch(1.1, x:, y:)
    check("reversing at minimum zoom responds immediately", (get(:reader)[:zoom] - 0.55).abs < 0.00001)
    @automation.pinch(1.0, phase: :cancelled, x:, y:)
    zoom = get(:reader)[:zoom]
    @automation.pinch(1.5, x:, y:)
    check("cancelled gestures ignore late changes", get(:reader)[:zoom] == zoom)
    settle
    @app.fit_pdf_page
    @app.turn_page(7)
    settle
    check("Fit restores fitted scale and horizontal position after a pinch", get(:reader)[:zoom] == 1.0 && get(:pdf_pan).zero? && get(:fit_button).state == "disabled")

    scroll = surface.scroll_top
    @automation.wheel(40, x:, y:)
    settle
    check("ordinary two-finger scrolling keeps its distance and scale", surface.scroll_top == scroll + 40 && get(:reader)[:zoom] == 1.0)
    @automation.wheel(-20, x:, y:, ctrl: true)
    zoom = get(:reader)[:zoom]
    check("Control-wheel zoom preserves fractional wheel deltas", (zoom - Math.exp(0.06)).abs < 1e-9)
    @automation.wheel(20, x:, y:, ctrl: true)
    check("opposite Control-wheel input restores scale", (get(:reader)[:zoom] - 1.0).abs < 1e-9)
    settle
    check("Control-wheel does not also scroll the document", (surface.scroll_top - scroll - 40).abs <= 1)

    if Gem.win_platform? && ENV["SCARPE_NATIVE_GHOST"] == "1"
      before = get(:reader)[:zoom]
      @automation.windows_zoom_wheel(30, x:, y:)
      check("Windows HWND preserves synthetic Control without a held key and without duplicate zoom", (get(:reader)[:zoom] - before * Math.exp(0.03)).abs < 1e-9)
      @automation.windows_zoom_wheel(-30, x:, y:)
      check("Windows HWND delivers signed high-resolution pinch input", (get(:reader)[:zoom] - before).abs < 1e-9)
      settle
    end

    text = @automation.rect_of!(get(:text_surface).linkable_id)
    tx, ty = text.center
    zoom = get(:reader)[:zoom]
    @automation.pinch(1.2, phase: :started, x: tx, y: ty)
    @automation.pinch(1.2, x:, y:)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    @automation.wheel(-40, x: tx, y: ty, ctrl: true)
    check("text-pane gestures do not zoom the PDF, even when crossing into it", get(:reader)[:zoom] == zoom)
    @automation.pinch(1.0, phase: :started, x:, y:)
    @automation.pinch(1.2, x: tx, y: ty)
    @automation.pinch(1.2, x:, y:)
    check("leaving the PDF pane cancels gesture capture", get(:reader)[:zoom] == zoom)

    @app.open_dialog(:reader_options)
    @automation.pinch(1.3, phase: :started, x:, y:)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    @automation.wheel(-40, x:, y:, ctrl: true)
    check("reader dialogs block background PDF gestures", get(:reader)[:zoom] == zoom)
    @app.close_dialog
    @automation.pinch(1.0, phase: :started, x:, y:)
    @app.turn_page(12)
    settle
    @automation.pinch(1.3, x:, y:)
    check("page navigation discards an unfinished gesture", get(:reader)[:zoom] == zoom)
    @automation.pinch(1.0, phase: :started, x:, y:)
    @automation.resize(1000, 760)
    settle
    @automation.pinch(1.3, x:, y:)
    check("window resize discards an unfinished gesture", get(:reader)[:zoom] == zoom)
    @automation.resize(1160, 820)
    @app.change_reader_mode(:text)
    settle_text_pinch(zoom, x, y)
    @app.change_reader_mode(:pdf)
    settle
    rect = @automation.rect_of!(surface.linkable_id)
    x, y = rect.center
    @automation.pinch(1.15, phase: :started, x:, y:)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    check("pinch works in PDF-only mode", (get(:reader)[:zoom] - zoom * 1.15).abs < 1e-9)
    settle
    @app.change_reader_mode(:split)
    settle
    @app.fit_pdf_page
    @app.turn_page(36)
    settle
    rect = @automation.rect_of!(surface.linkable_id)
    x, y = rect.center
    @automation.pinch(2.5, phase: :started, x:, y:)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    settle
    check("pinching on the last short page retains valid scroll and visible pixels", surface.scroll_top == view.clamp(surface.scroll_top) && get(:page_image) && get(:reader)[:number] == 36)
    @app.fit_pdf_page
    @app.turn_page(9)
    settle
  end

  def settle_text_pinch(zoom, x, y)
    @automation.wait_frames
    @automation.pinch(1.3, phase: :started, x:, y:)
    @automation.pinch(1.0, phase: :ended, x:, y:)
    check("text-only mode ignores PDF zoom gestures", get(:reader)[:zoom] == zoom && surface.nil?)
  end
end
