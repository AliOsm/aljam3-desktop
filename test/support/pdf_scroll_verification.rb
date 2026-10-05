# frozen_string_literal: true

require "timeout"
require "json"
require_relative "range_pdf"
require_relative "motion_preference"

# Measures first displayed pixels while real wheel input continues, including
# the Ruby worker, PDFium, native image upload/decoding and a painted frame.
# A delayed local range server isolates scheduling from Internet variability.
class PDFScrollVerification
  def initialize(app, automation, output:, strict: true)
    @app, @automation, @output, @strict = app, automation, output, strict
    @checks = []
  end

  def call(sample: nil)
    MotionPreference.set(@app, reduced: true)
    real = sample && File.file?(sample)
    data = real ? File.binread(sample) : RangePDF.image_document(pages: 96)
    reports = {}
    RangePDF.serve(data, delay: 0.04) do |url, requests|
      reports[:online] = exercise(:online, url, data)
      reports[:online][:range_requests] = requests.size
      reports[:online][:range_delay_ms] = 40
      reports[:offline] = exercise(:offline, url, data)
    end
    result = { passed: @checks.all? { |item| item[:passed] }, fixture: real ? "96-page scanned book 1" : "96-page generated image PDF",
      measurements: reports, checks: @checks }
    File.write(File.join(@output, "scroll-performance.json"), JSON.pretty_generate(result))
    result
  ensure
    @app.navigate(:home)
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def ready? = get(:screen) == :reader && get(:reader)&.dig(:image) && get(:page_image)&.url == get(:reader)[:image].path
  def visible_ready?
    view.visible(surface.scroll_top).all? do |page|
      pixels = get(:pdf_images)[page]
      pixels && get(:pdf_nodes).dig(page, :image)&.url == pixels.path
    end
  end
  def view = get(:pdf_viewport)
  def surface = get(:pdf_surface)

  def check(message, condition)
    raise message if @strict && !condition

    @checks << { check: message, passed: !!condition }
  end

  def frame
    @app.tick
    @automation.wait_frames
  end

  def wait_until
    Timeout.timeout(30) do
      loop do
        frame
        break if yield

        sleep 0.003
      end
    end
  end

  def settle
    wait_until { ready? && !get(:pdf_pending) && !get(:pdf_render_due) && !get(:reader)[:loading_text] }
  end

  def wheel_to(page)
    rect = @automation.rect_of!(surface.linkable_id)
    @automation.wheel(view.top(page) - surface.scroll_top, x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
  end

  def seek(page)
    started = now
    wheel_to(page)
    wait_until { get(:reader)[:number] == page && ready? }
    first = (now - started) * 1000
    settle
    { page:, first_pixels_ms: first.round(2), sharp_and_prefetched_ms: ((now - started) * 1000).round(2) }
  end

  def exercise(mode, url, data)
    @app.navigate(:home)
    # Finish the previous worker before replacing its renderer and source.
    drained = false
    get(:render_worker).submit(-> { nil }) { drained = true }
    wait_until { drained }
    get(:pdf).close if get(:pdf).respond_to?(:close)
    id = mode == :online ? 980_001 : 980_002
    book = { "id" => id, "title" => "قياس سلاسة القراءة", "pages_count" => 96, "files_count" => 1,
      "files" => [{ "id" => id, "name" => "المجلد", "pages_count" => 96, "urls" => { "pdf" => url } }] }
    api, store = get(:api), get(:store)
    api.define_singleton_method(:book) { |_id| book }
    api.define_singleton_method(:connection) { mode == :offline ? :offline : :online }
    api.define_singleton_method(:page) { |file, number| { "id" => file + number, "number" => number, "content" => "نص الصفحة #{number}" } }
    if mode == :offline
      store.prepare_download(book)
      store.add_pages(id, (1..96).map { |number| { "id" => id + number, "number" => number, "content" => "نص الصفحة #{number}" } })
      path = get(:downloader).pdf_path(id, id)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, data)
      store.complete_download(id)
      @app.refresh_download_state
      api.define_singleton_method(:page) { |*| raise "Offline scrolling made a network request" }
    end
    cache = File.join(Aljam3.data_directory, "scroll-#{mode}")
    pdf = Aljam3::PDF.new(cache:)
    @app.instance_variable_set(:@pdf, pdf)
    completions = []
    method = pdf.respond_to?(:render_bitmap) ? :render_bitmap : :render
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    pdf.define_singleton_method(method) do |source, page:, **options|
      result = super(source, page:, **options)
      completions << { page:, at: clock.call }
      result
    end
    store.save_preference("reader", { "mode" => "split" })
    @app.tick
    @app.open_book(book)
    settle

    # Continuous input; do not wait for a page to render between wheel events.
    started, missing, partial, worst_blank, blank_since = now, 0, 0, 0, nil
    start_offset, wheel_distance = surface.scroll_top, 0
    first_completion = completions.size
    active_pages = []
    intervals, previous = [], started
    120.times do |index|
      intervals << (now - previous) * 1000 if index.positive?
      previous = now
      rect = @automation.rect_of!(surface.linkable_id)
      distance = view.height * 0.08
      wheel_distance += distance
      @automation.wheel(distance, x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
      frame
      active_pages << get(:reader)[:number]
      partial += 1 unless visible_ready?
      if ready?
        worst_blank = [worst_blank, now - blank_since].max if blank_since
        blank_since = nil
      else
        missing += 1
        blank_since ||= now
      end
      remaining = started + (index + 1).fdiv(60) - now
      sleep remaining if remaining.positive?
    end
    duration = now - started
    during = completions.size - first_completion
    scroll_distance = surface.scroll_top - start_offset
    settle
    worst_blank = [worst_blank, now - blank_since].max if blank_since
    check("#{mode}: pages render while wheel input continues", during >= 3)
    check("#{mode}: scrolling crosses at least eight pages", active_pages.uniq.size >= 8)
    check("#{mode}: page updates preserve wheel distance", (scroll_distance - wheel_distance).abs < 2)
    check("#{mode}: visible-page loading occupies under 20% of continuous-scroll samples", missing < 24)
    check("#{mode}: every visible page has pixels in at least 80% of scroll samples", partial <= 24)

    jumps = [96, 48].map { |page| seek(page) }
    check("#{mode}: uncached long seeks produce pixels within 1.5 seconds", jumps.all? { |jump| jump[:first_pixels_ms] < 1500 })
    # Page 96 was recently displayed. It must appear synchronously from cache,
    # before a worker or another timer has an opportunity to finish anything.
    before = completions.count { |event| event[:page] == 96 }
    started = now
    @app.turn_page(96)
    immediate = ready?
    frame
    cached_ms = (now - started) * 1000
    check("#{mode}: returning to a recent page has no loading placeholder", immediate)
    settle
    check("#{mode}: returning to a recent page does not render it again", completions.count { |event| event[:page] == 96 } == before)
    if @app.respond_to?(:pdf_image_bytes)
      check("#{mode}: retained page pixels stay within 32 MiB", @app.pdf_image_bytes <= Aljam3::UI::ReaderPDF::PDF_MEMORY_BYTES)
      check("#{mode}: scrolling writes no PNG files", Dir.glob(File.join(cache, "*.png")).empty?)
    end
    @automation.snapshot(File.join(@output, "scroll-#{mode}.png"))
    { wheel_samples: 120, duration_ms: (duration * 1000).round(2), pages_crossed: active_pages.uniq.size,
      input_interval_p95_ms: intervals.sort[(intervals.size * 0.95).floor].round(2),
      initial_scroll: start_offset, requested_scroll_distance: wheel_distance.round(2), actual_scroll_distance: scroll_distance.round(2),
      first_page: active_pages.first, last_page: active_pages.last,
      renders_during_scrolling: during, missing_image_samples: missing, missing_image_percent: (missing / 1.2).round(2),
      incomplete_viewport_samples: partial, incomplete_viewport_percent: (partial / 1.2).round(2),
      longest_blank_ms: (worst_blank * 1000).round(2), long_seeks: jumps,
      cached_return_ms: cached_ms.round(2), cached_return_immediate: !!immediate,
      retained_pixel_bytes: @app.respond_to?(:pdf_image_bytes) ? @app.pdf_image_bytes : nil }
  end
end
