# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/reader_pdf"
require_relative "../lib/aljam3/pdf"

class ReaderSchedulingTest < Minitest::Test
  class Reader
    include Aljam3::UI::ReaderPDF
    class Surface
      attr_reader :scroll_top, :assignments

      def initialize
        @scroll_top, @assignments = 0, []
      end

      def scroll_top=(value)
        @assignments << value
        @scroll_top = value
      end
    end
    Worker = Struct.new(:jobs) do
      def submit(work, &callback) = jobs << [work, callback]
      def drain; end
    end
    attr_reader :render_worker, :reader, :pdf_viewport, :pdf_surface, :released

    def initialize
      @screen, @render_number = :reader, 1
      @reader = { number: 1, zoom: 1.0, mode: :pdf, book: { "id" => 1 }, file: { "id" => 1 }, loading_text: false }
      @pdf_surface = Surface.new
      @pdf_viewport = Aljam3::PDFViewport.new(count: 100)
      @pdf_viewport.resize(width: 600, height: 700, zoom: 1.0)
      @pdf_width, @pdf_height, @pdf_direction, @pdf_scroll_speed = 600, 700, 1, 0
      @pdf_canvas = Struct.new(:height).new(@pdf_viewport.total_height)
      @pdf_images, @pdf_failures, @released = {}, {}, []
      @render_worker, @page_worker = Worker.new([]), Worker.new([])
    end

    def reader_pdf? = true
    def start_reader_pump; end
    def draw_pdf_image; end
    def remember_pdf_anchor; end
    def activate_reader_page(number, **) = @reader[:number] = number
    def release_pdf_image(image) = @released << image.path
    def cache_pdf_image(number, image)
      @pdf_images[number] = image
      trim_pdf_images
    end

    def scroll(page)
      @pdf_surface.scroll_top = @pdf_scroll_pending = @pdf_viewport.top(page)
      pump_reader
    end

    def pixels = @pdf_images
  end

  def test_continuous_scroll_input_does_not_postpone_all_render_requests
    reader = Reader.new
    clock = 100.0
    Process.stub(:clock_gettime, ->(*) { clock }) do
      (1..20).each do |page|
        clock += 0.016
        reader.scroll(page)
        assert_operator reader.render_worker.jobs.size, :>, 0, "Page scheduling must not require a pause in scroll input"
      end
    end
    assert_equal 20, reader.reader[:number]
    assert_equal 20, reader.instance_variable_get(:@pdf_pending).last
  end

  def test_visible_cache_hits_are_not_discarded_with_the_virtual_nodes
    reader = Reader.new
    image = Struct.new(:path, :width, :height)
    reader.pixels[1] = image.new("memory:first", 512, 700)
    reader.scroll(80)
    reader.trim_pdf_images
    assert reader.pixels.key?(1), "A long jump must keep recent pixels while within budget"
    assert_empty reader.released
    40.times { |i| reader.pixels[i + 30] = image.new("memory:#{i}", 1024, 1024) }
    reader.trim_pdf_images
    assert_operator reader.pdf_image_bytes, :<=, Aljam3::UI::ReaderPDF::PDF_MEMORY_BYTES
    assert_operator reader.released.size, :>, 0, "Eviction must release the native pixel allocation too"
  end

  def test_learning_portrait_dimensions_does_not_overwrite_scroll_input
    reader = Reader.new
    reader.pdf_surface.scroll_top = 100
    reader.request_pdf_page
    reader.render_worker.jobs.shift.last.call(Struct.new(:path, :width, :height).new("memory:portrait", 480, 640), nil)
    assert_equal [100], reader.pdf_surface.assignments,
      "A completed page must not send an absolute scroll when fitted page height is unchanged"
  end

  def test_prefetch_stops_before_retained_pages_start_evicting_one_another
    reader = Reader.new
    image = Struct.new(:path, :width, :height)
    [1, 2].each { |page| reader.pixels[page] = image.new("memory:visible#{page}", 2000, 1800) }
    reader.instance_variable_set(:@pdf_scroll_speed, 10_000)
    # The unusually tall last page cannot fit the remaining budget either.
    reader.pdf_viewport.learn(8, width: 240, height: 7200)
    reader.request_pdf_page
    rendered = []
    12.times do
      job = reader.render_worker.jobs.shift
      break unless job

      number = reader.instance_variable_get(:@pdf_pending).last
      rendered << number
      job.last.call(image.new("memory:#{number}", 480, 680), nil)
    end
    assert_equal [3, 4, 5], rendered
    assert_nil reader.instance_variable_get(:@pdf_pending), "Prefetch must settle without an eviction/render loop"
    assert_empty reader.released
    assert_operator reader.pdf_image_bytes, :<=, Aljam3::UI::ReaderPDF::PDF_MEMORY_BYTES
  end

  def test_pinch_scales_immediately_but_coalesces_rendering_until_a_pause
    reader = Reader.new
    clock = 100.0
    Process.stub(:clock_gettime, ->(*) { clock }) do
      reader.pinch_pdf(1.0, "started", 300, 240)
      80.times do
        clock += 0.008
        reader.pinch_pdf(1.008, "moved", 300, 240)
        reader.pump_reader
        assert_empty reader.render_worker.jobs, "Rendering should wait while cached pixels are being scaled"
      end
      assert_in_delta 1.008**80, reader.reader[:zoom], 1e-10
      clock += 0.15
      reader.pump_reader
      assert_equal 1, reader.render_worker.jobs.size, "A pause sharpens even before the fingers lift"
      reader.pinch_pdf(1.1, "moved", 300, 240)
      stale = reader.render_worker.jobs.last
      assert_raises(Aljam3::PDF::Cancelled) { stale.first.call }
      reader.pinch_pdf(1.0, "ended", 300, 240)
      assert_nil reader.instance_variable_get(:@pdf_pinch)
      clock += 0.15
      reader.pump_reader
      assert_equal 2, reader.render_worker.jobs.size
    end
  end

  def test_pinch_limits_reverse_immediately_and_reject_invalid_input
    reader = Reader.new
    reader.pinch_pdf(1.0, "started", 300, 200)
    reader.pinch_pdf(100, "moved", 300, 200)
    assert_equal 3.0, reader.reader[:zoom]
    reader.pinch_pdf(0.9, "moved", 300, 200)
    assert_in_delta 2.7, reader.reader[:zoom]
    reader.pinch_pdf(0.001, "moved", 300, 200)
    assert_equal 0.5, reader.reader[:zoom]
    reader.pinch_pdf(1.1, "moved", 300, 200)
    assert_in_delta 0.55, reader.reader[:zoom]
    [0, -1, Float::NAN, Float::INFINITY].each { |factor| reader.pinch_pdf(factor, "moved", 300, 200) }
    assert_in_delta 0.55, reader.reader[:zoom]
    reader.pinch_pdf(1.0, "cancelled", 300, 200)
    reader.pinch_pdf(2.0, "moved", 300, 200)
    assert_in_delta 0.55, reader.reader[:zoom], 0.0001, "Late events cannot resume a cancelled gesture"
  end

  def test_wheel_gestures_get_new_anchors_after_a_pause_and_do_not_survive_navigation
    reader = Reader.new
    clock = 100.0
    Process.stub(:clock_gettime, ->(*) { clock }) do
      reader.pinch_pdf(1.1, "wheel", 240, 200)
      first = reader.instance_variable_get(:@pdf_pinch)[:anchor]
      clock += 0.02
      reader.pinch_pdf(1.1, "wheel", 240, 200)
      assert_same first, reader.instance_variable_get(:@pdf_pinch)[:anchor]
      clock += 0.2
      reader.pinch_pdf(1.1, "wheel", 340, 300)
      refute_same first, reader.instance_variable_get(:@pdf_pinch)[:anchor]
      clock += 0.15
      reader.pump_reader
      assert_nil reader.instance_variable_get(:@pdf_pinch), "Wheel sequences end after a pause without an OS end event"
      reader.pinch_pdf(1.0, "started", 300, 200)
      reader.jump_pdf_page(12)
      before = reader.reader[:zoom]
      reader.pinch_pdf(1.5, "moved", 340, 300)
      assert_equal before, reader.reader[:zoom]
      assert_nil reader.instance_variable_get(:@pdf_pinch)
      reader.instance_variable_set(:@dialog, { type: :reader_options })
      reader.pinch_pdf(1.5, "started", 300, 200)
      assert_equal before, reader.reader[:zoom]
    end
  end
end
