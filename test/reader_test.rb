# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/reader"
require_relative "../lib/aljam3/ui/navigation"
require_relative "../lib/aljam3/ui/reader_tools"
require_relative "../lib/aljam3/ui/downloads"
require "timeout"

class ReaderTest < StoreTestCase
  class Reader
    include Aljam3::UI::Reader
    include Aljam3::UI::Navigation
    include Aljam3::UI::ReaderTools
    include Aljam3::UI::DownloadScreen
    attr_reader :reader, :renders

    def initialize(store)
      @store = store
      @downloaded_ids = store.downloaded_ids
      @request_number = 0
      @renders = []
    end

    def draw_window; end
    def refresh_window; end
    def page_text_control
      @page_text ||= Struct.new(:text) do
        def style(**); end
        def replace(*parts) = self.text = parts.join
      end.new
    end
    def text_controls
      @page_text = page_text_control
    end
    def render_pdf
      @renders << [@reader.fetch(:file).fetch("id"), @reader.fetch(:number), @reader.fetch(:zoom)]
    end
  end

  def test_search_result_opens_and_remembers_the_correct_volume_and_page
    volumes = book.fetch("files") + [book(2).fetch("files").first]
    @store.prepare_download(book.merge("files" => volumes))
    @store.add_pages(10, pages)
    @store.add_pages(20, pages(2))
    @store.complete_download(1)
    reader = Reader.new(@store)
    reader.open_book(book, page_id: 201)

    assert_equal 20, reader.reader.fetch(:file).fetch("id")
    assert_equal 2, reader.reader.fetch(:number)
    assert_equal :split, reader.reader.fetch(:mode)
    assert_equal [[20, 2, 1.0]], reader.renders
    assert_nil reader.reader[:notice]
    assert_equal({ "file_id" => 20, "number" => 2 }, @store.preference("reading:1"))

    reopened = Reader.new(@store)
    reopened.open_book(book)
    assert_equal 20, reopened.reader.fetch(:file).fetch("id")
    assert_equal 2, reopened.reader.fetch(:number)
  end

  def test_missing_search_page_explains_fallback_to_start_of_book
    install_book
    reader = Reader.new(@store)
    reader.open_book(book, page_id: 999)
    assert_equal 1, reader.reader.fetch(:number)
    refute_nil reader.reader[:notice]
    reader.turn_page(2)
    assert_nil reader.reader[:notice]
  end

  def test_changing_views_preserves_the_page_and_zoom_and_renders_both_pdf_views
    install_book
    reader = Reader.new(@store)
    reader.open_book(book)
    reader.turn_page(2)
    reader.change_reader_mode(:text)
    reader.change_zoom(0.25)
    assert_equal [[10, 1, 1.0], [10, 2, 1.0]], reader.renders

    reader.change_reader_mode(:split)
    assert_equal [10, 2, 1.25], reader.renders.last
    reader.change_reader_mode(:pdf)
    assert_equal [10, 2, 1.25], reader.renders.last
    assert_equal 4, reader.renders.length
    assert_equal({ "file_id" => 10, "number" => 2 }, @store.preference("reading:1"))
  end

  def test_fit_disables_at_fitted_zoom_and_does_not_rerender_repeatedly
    install_book
    reader = Reader.new(@store)
    reader.open_book(book)
    control = Struct.new(:options) { def style(**options) = self.options = options }
    fit, zoom_in, zoom_out = Array.new(3) { control.new }
    reader.instance_variable_set(:@fit_button, fit)
    reader.instance_variable_set(:@zoom_in_button, zoom_in)
    reader.instance_variable_set(:@zoom_out_button, zoom_out)
    reader.update_pdf_controls
    assert_equal "disabled", fit.options[:state]
    reader.reader[:image] = true
    reader.change_zoom(0.5)
    assert_nil fit.options[:state]
    reader.fit_pdf_page
    assert_equal 1.0, reader.reader[:zoom]
    assert_equal "disabled", fit.options[:state]
    count = reader.renders.length
    reader.fit_pdf_page
    assert_equal count, reader.renders.length
    reader.change_zoom(10)
    assert_equal "disabled", zoom_in.options[:state]
    reader.change_zoom(-10)
    assert_equal "disabled", zoom_out.options[:state]
  end

  def test_text_options_are_independent_of_pdf_zoom_and_persist_when_reopened
    install_book
    reader = Reader.new(@store)
    reader.open_book(book)
    reader.text_controls
    original = reader.page_text
    reader.change_text_size(2)
    reader.toggle_tashkeel
    assert_equal "آداب العلم وأهله في الإسلام", reader.page_text
    assert_equal original, @store.page(10, 1).fetch("content")
    assert_equal 1, reader.renders.length
    assert_equal 1.0, reader.reader.fetch(:zoom)
    reader.change_zoom(0.5)
    assert_equal 22, reader.reader.fetch(:text_size)

    reopened = Reader.new(@store)
    reopened.open_book(book)
    assert_equal 22, reopened.reader.fetch(:text_size)
    refute reopened.reader.fetch(:tashkeel)
    assert_equal 1.0, reopened.reader.fetch(:zoom)
  end

  def test_rapid_page_changes_fetch_only_the_latest_queued_page
    reader = Reader.new(@store)
    worker = Aljam3::Worker.new
    gate, finished, calls = Queue.new, Queue.new, []
    worker.submit(-> { gate.pop }) { |*| }
    reading = Object.new
    reading.define_singleton_method(:page) do |_book_id, _file_id, number|
      calls << number
      { "number" => number, "content" => "page #{number}" }
    end
    reader.instance_variable_set(:@page_worker, worker)
    reader.instance_variable_set(:@reading, reading)
    volume = book
    volume.fetch("files").first["pages_count"] = 50
    reader.start_reader(volume)
    (2..50).each { |number| reader.turn_page(number) }
    worker.submit(-> { finished << true }) { |*| }
    gate << true
    Timeout.timeout(5) { finished.pop }
    worker.drain

    assert_equal [50], calls
    assert_equal 50, reader.reader.dig(:page, "number")
    refute reader.reader[:loading_text]
  ensure
    worker&.close
  end

  def test_superseded_book_openings_do_not_delay_the_latest_book
    reader = Reader.new(@store)
    worker = Aljam3::Worker.new
    gate, finished, calls, opened = Queue.new, Queue.new, [], []
    worker.submit(-> { gate.pop }) { |*| }
    reading = Object.new
    books = (1..5).to_h { |id| [id, book(id)] }
    reading.define_singleton_method(:book) { |id| calls << id; books.fetch(id) }
    reader.define_singleton_method(:start_reader) { |book, **| opened << book.fetch("id") }
    reader.instance_variable_set(:@network_worker, worker)
    reader.instance_variable_set(:@reading, reading)
    reader.instance_variable_set(:@screen, :home)
    books.each_value { |book| reader.open_book(book) }
    worker.submit(-> { finished << true }) { |*| }
    gate << true
    Timeout.timeout(5) { finished.pop }
    worker.drain

    assert_equal [5], calls
    assert_equal [5], opened
  ensure
    worker&.close
  end
end
