# frozen_string_literal: true

require "timeout"
require "digest"
require_relative "range_pdf"
require_relative "motion_preference"
require_relative "pdf_pinch_verification"

# Real native input, PDFium, HTTP ranges, SQLite and worker completion. Shared by
# source checks and the relocated Mac/Windows applications with their bundled Ruby.
class ContinuousReaderVerification
  include PDFPinchVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks = []
  end

  def call
    MotionPreference.set(@app, reduced: true)
    @app.navigate(:home)
    get(:pdf).close
    @app.instance_variable_set(:@pdf, Aljam3::PDF.new(cache: File.join(Aljam3.data_directory, "continuous-renders")))
    data = RangePDF.document(pages: 36, sizes: { 3 => [600, 240], 9 => [240, 700], 36 => [600, 240] })
    RangePDF.serve(data) do |url, ranges|
      book = { "id" => 970_000, "title" => "اختبار القراءة المتصلة", "pages_count" => 36, "files_count" => 1,
        "files" => [{ "id" => 970_000, "name" => "الكتاب", "pages_count" => 36, "urls" => { "pdf" => url } }] }
      api, calls = get(:api), []
      api.define_singleton_method(:book) { |_id| book }
      api.define_singleton_method(:connection) { :online }
      api.define_singleton_method(:page) do |file, number|
        calls << number
        { "id" => file + number, "number" => number, "content" => "نص الصفحة #{number}. " * 60 }
      end
      get(:store).save_preference("reader", { "mode" => "split" })
      @app.tick # Publish the fixture's online connection before opening an online book.
      @app.open_book(book)
      settle
      check("only the active page text is fetched", calls == [1])
      check("initial reading uses a fraction of the remote PDF", ranges.sum(&:last) < data.bytesize / 3)
      check_page(1)
      image_slot = get(:pdf_surface).linkable_id
      wheel(view.top(3) - surface.scroll_top)
      settle
      check_page(3)
      check("wheel navigation keeps the same scroll surface", get(:pdf_surface).linkable_id == image_slot)
      check("mixed landscape dimensions are learned", view.dimensions(3).first > view.dimensions(3).last)
      shot("continuous-landscape")

      # Burst input should not enqueue text for every page crossed.
      before = calls.size
      [8, 14, 20, 27].each { |page| wheel(view.top(page) - surface.scroll_top); @app.pump_reader }
      settle
      check_page(27)
      check("fast scrolling coalesces text requests", calls.size - before <= 2)
      check("decoded pages stay bounded after a long seek", @app.pdf_image_bytes <= Aljam3::UI::ReaderPDF::PDF_MEMORY_BYTES && get(:pdf_nodes).size <= 5)
      @app.toggle_reader_bookmark
      check("bookmarks follow the visible PDF page", get(:store).bookmarks(book.fetch("id")).last.fetch("number") == 27)

      @app.turn_page(9)
      settle
      @app.change_zoom(0.5)
      settle
      wheel(160)
      settle
      anchor = view.anchor(surface.scroll_top)
      previous = get(:page_image)
      previous_path, previous_width = previous.url, previous.width
      @app.change_zoom(0.5)
      check("zoom resizes the existing image immediately", get(:page_image).equal?(previous) && previous.url == previous_path && previous.width > previous_width)
      check("zoom preserves the reading anchor", near_anchor?(anchor, view.anchor(surface.scroll_top)))
      settle
      check("sharp zoom pixels replace the preview", get(:reader).fetch(:image).width >= @app.pdf_render_width)
      @app.fit_pdf_page
      settle
      check("fit returns to the active page", get(:reader)[:zoom] == 1.0 && (surface.scroll_top - view.top(9)).abs < 2)
      check("fit is disabled at fitted size", get(:fit_button).state == "disabled")

      pinch_gestures

      appearance
      modes_and_resize
      pan_release
      scrollbar
      @app.turn_page(36)
      settle
      check_page(36)
      check("last short page remains reachable", (surface.scroll_top - view.top(36)).abs < 2 && get(:next_page_button).state == "disabled")
      @app.turn_page(1)
      settle
      check("first-page navigation clamps correctly", get(:previous_page_button).state == "disabled")
      loading_placeholder
      failures_and_retry
      get(:reader)[:query] = "الصفحة"
      @app.draw_window
      @app.turn_page(31)
      settle
      check("match navigation enables after asynchronous text arrives", get(:next_match_button).state.nil?)
      @automation.click({ id: get(:next_match_button).linkable_id })
      check("match navigation follows the newly loaded page", get(:reader)[:match_index] == 1)
      @app.clear_reader_matches

      # Same reader against a completed local download; network must not be used.
      store = get(:store)
      store.prepare_download(book)
      store.add_pages(970_000, (1..36).map { |number| { "id" => 970_000 + number, "number" => number, "content" => "نص محلي #{number}" } })
      path = get(:downloader).pdf_path(970_000, 970_000)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, data)
      store.complete_download(970_000)
      @app.refresh_download_state
      api.define_singleton_method(:page) { |*| raise "Offline reading attempted an API request" }
      api.define_singleton_method(:connection) { :offline }
      @app.navigate(:home)
      @app.open_book(book)
      settle
      wheel(view.top(18) - surface.scroll_top)
      settle
      check_page(18)
      check("offline scrolling loads text from SQLite", @app.page_text == "نص محلي 18")
      pinch_gestures(offline: true)
      @app.close_reader
      @app.open_book(book)
      settle
      check_page(18)
      check("reopening restores the last read page", store.preference("reading:970000").fetch("number") == 18)
      shot("continuous-offline")
      { passed: true, checks: @checks, range_requests: ranges.size, text_requests: calls }
    end
  ensure
    @app.navigate(:home)
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def view = get(:pdf_viewport)
  def surface = get(:pdf_surface)
  def check(message, condition)
    raise message unless condition

    @checks << message
  end

  def settle
    Timeout.timeout(20) do
      loop do
        @app.tick
        @automation.wait_frames
        break if get(:screen) == :reader && !get(:reader)[:loading_text] && !get(:pdf_pending) && !get(:pdf_render_due) && !get(:pdf_scroll_pending) && get(:reader)[:image]

        sleep 0.005
      end
    end
    raise get(:reader)[:pdf_error] if get(:reader)[:pdf_error]
  rescue Timeout::Error
    shot("continuous-timeout")
    raise "Reader did not settle (screen=#{get(:screen)}, dialog=#{get(:dialog)&.dig(:type)}): #{get(:reader)&.except(:book, :files, :file, :page).inspect}; pending=#{get(:pdf_pending).inspect}, errors=#{get(:pdf_failures).inspect}, scroll=#{surface&.scroll_top}, due=#{get(:pdf_render_due)}"
  end

  def wheel(distance)
    rect = @automation.rect_of!(surface.linkable_id)
    @automation.wheel(distance, x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
  end

  def check_page(number)
    reader = get(:reader)
    warn "Expected page #{number}, got #{reader[:number]} / #{reader.dig(:page, 'number')}, scroll #{surface.scroll_top}" if reader[:number] != number
    check("page #{number}: counter, text, image and progress agree", reader[:number] == number &&
      reader.dig(:page, "number") == number && get(:page_field).text == number.to_s &&
      get(:page_image)&.url == get(:pdf_images)[number]&.path &&
      get(:store).preference("reading:970000").fetch("number") == number)
  end

  def near_anchor?(a, b) = a.first == b.first && (a[1] - b[1]).abs < 0.005

  def shot(name, **options) = @automation.snapshot(File.join(@output, "#{name}.png"), **options)

  def appearance
    @app.turn_page(1)
    settle
    original = get(:reader).fetch(:image)
    digest = Digest::SHA256.hexdigest(original.pixels)
    @app.open_dialog(:reader_options)
    @automation.click({ id: get(:appearance_buttons).fetch("night").linkable_id })
    check("night preference persists", get(:store).preference("reader").fetch("pdf_appearance") == "night")
    shot("reading-options-night")
    @app.close_dialog
    @automation.wait_frames
    rect = @automation.rect_of!(get(:page_image).linkable_id)
    check("PDF paper changes to the night palette", @automation.pixel(rect.x + rect.w - 8, rect.y + 8).first(3) == [30, 27, 26])
    check("night mode leaves original export pixels untouched", Digest::SHA256.hexdigest(original.pixels) == digest)
    shot("continuous-night")
    @app.change_pdf_appearance("original")
    @automation.wait_frames
    check("original colors remain available", @automation.pixel(rect.x + rect.w - 8, rect.y + 8).first(3) == [255, 255, 255])
    @app.change_pdf_appearance("auto")
    @app.toggle_theme if get(:theme) != :dark
    settle
    check("automatic PDF appearance follows dark theme", get(:page_image).night_mode)
    @app.toggle_theme
    settle
    check("automatic PDF appearance follows light theme", !get(:page_image).night_mode)
  end

  def modes_and_resize
    @app.turn_page(12)
    settle
    @app.change_zoom(0.5)
    settle
    wheel(80)
    settle
    anchor = view.anchor(surface.scroll_top)
    @app.change_reader_mode(:text)
    @app.change_reader_mode(:split)
    settle
    check("switching reader modes preserves position", near_anchor?(anchor, view.anchor(surface.scroll_top)))
    @automation.resize(900, 700)
    settle
    check("resizing preserves position", near_anchor?(anchor, view.anchor(surface.scroll_top)))
    @app.change_reader_mode(:pdf)
    settle
    check("PDF-only reading keeps the active page", get(:reader)[:number] == 12)
    @app.change_reader_mode(:split)
    @automation.resize(1160, 820)
    settle
    @app.fit_pdf_page
    settle
  end

  def scrollbar
    @app.turn_page(1)
    settle
    rect = @automation.rect_of!(surface.linkable_id)
    @automation.mouse(:down, rect.x + 5, rect.y + 10)
    @automation.mouse(:move, rect.x + 5, rect.y + rect.h * 0.65)
    @automation.mouse(:up, rect.x + 5, rect.y + rect.h * 0.65)
    settle
    check("dragging the RTL scrollbar seeks through the volume", get(:reader)[:number] > 10)
  end

  def pan_release
    @app.change_zoom(2)
    settle
    rect = @automation.rect_of!(surface.linkable_id)
    x, y = rect.center
    initial = get(:page_image).left
    @automation.mouse(:down, x, y)
    @automation.mouse(:move, x + 40, y)
    before = get(:page_image).left
    check("a held primary-button drag pans the zoomed PDF", before == initial + 40)
    @automation.mouse(:up, x + 40, rect.y - 30)
    @automation.mouse(:move, x + 100, y)
    check("PDF panning stops when released outside the pane", get(:page_image).left == before)
    @automation.mouse(:down, x, y)
    @automation.mouse(:up, -10, -10)
    @automation.mouse(:move, x + 100, y)
    check("PDF panning stops when released outside the window", get(:page_image).left == before)
    @app.fit_pdf_page
    settle
    check("fitting a page resets horizontal panning", get(:pdf_pan).zero?)
  end

  def loading_placeholder
    # Hold rendering long enough to exercise the real delayed loader, including
    # the geometry rebuilt by a window resize and a theme change.
    gate, entered = Queue.new, Queue.new
    get(:render_worker).submit(-> { entered << true; gate.pop }) { |*| }
    Timeout.timeout(5) { entered.pop }
    @app.release_pdf_images
    @app.turn_page(20)
    [[:light, 1160, 820], [:dark, 900, 700]].each do |theme, width, height|
      @app.toggle_theme unless get(:theme) == theme
      @automation.resize(width, height)
      Timeout.timeout(5) do
        until get(:pdf_nodes).dig(20, :loading)
          @app.tick
          @automation.wait_frames
          sleep 0.005
        end
      end
      node = get(:pdf_nodes).fetch(20)
      page = @automation.rect_of!(node.fetch(:placeholder).linkable_id)
      label = @automation.rect_of!(node.fetch(:loading).linkable_id)
      check("#{theme}: delayed PDF loading text is vertically centered after resize",
        (page.center.last - label.center.last).abs < 1)
      shot("continuous-loading-#{theme}", scale: 1)
      require "chunky_png"
      picture = ChunkyPNG::Image.from_file(File.join(@output, "continuous-loading-#{theme}.png"))
      paper = picture[page.center.first.round, (page.y + 8).round]
      columns = []
      label.y.ceil.upto((label.y + label.h).floor - 1) do |y|
        label.x.ceil.upto((label.x + label.w).floor - 1) do |x|
          # Include antialiased edges: thin glyphs need not contain any fully
          # opaque stroke pixels, depending on platform font rasterization.
          pixel = picture[x, y]
          contrast = %i[r g b].map { |channel| (ChunkyPNG::Color.public_send(channel, pixel) - ChunkyPNG::Color.public_send(channel, paper)).abs }.max
          columns << x if contrast >= 16
        end
      end
      check("#{theme}: delayed PDF loading text is horizontally centered on the paper",
        !columns.empty? && ((columns.min + columns.max) / 2.0 - page.center.first).abs < 4)
    end
    gate << true
    @app.toggle_theme
    @automation.resize(1160, 820)
    settle
    check_page(20)
    check("completed PDF pixels replace the centered loading label", !get(:pdf_nodes).fetch(20)[:loading])
  ensure
    gate << true if gate
  end

  def failures_and_retry
    pdf, api = get(:pdf), get(:api)
    original_page = api.method(:page)
    failed_pdf = failed_text = false
    pdf.define_singleton_method(:render_bitmap) do |source, page:, **options|
      if page == 30 && !failed_pdf
        failed_pdf = true
        raise Aljam3::ConnectionError, "Simulated page-range failure"
      end
      super(source, page:, **options)
    end
    api.define_singleton_method(:page) do |file, number|
      if number == 30 && !failed_text
        failed_text = true
        raise Aljam3::ConnectionError, "Simulated text failure"
      end
      original_page.call(file, number)
    end
    @app.turn_page(30)
    Timeout.timeout(10) do
      until get(:reader)[:pdf_error] && get(:reader)[:text_error]
        @app.tick
        @automation.wait_frames
        sleep 0.005
      end
    end
    check("failed page reads expose retry controls without crashing", get(:fit_button).state == "disabled")
    shot("continuous-retry")
    button = get(:pdf_nodes).fetch(30).fetch(:slot).contents.find { |node| node.is_a?(Shoes::Button) }
    @automation.click({ id: button.linkable_id })
    @automation.click({ id: get(:action_views).fetch("إعادة تحميل النص").linkable_id })
    settle
    check_page(30)
    check("PDF and text recover independently after a connection failure", !get(:reader)[:pdf_error] && !get(:reader)[:text_error])
  ensure
    pdf&.singleton_class&.remove_method(:render_bitmap)
    api&.define_singleton_method(:page, original_page) if original_page
  end
end
