# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/reader"

class ReaderTest < StoreTestCase
  class Reader
    include Aljam3::UI::Reader
    attr_reader :reader, :renders

    def initialize(store)
      @store = store
      @request_number = 0
      @renders = []
    end

    def draw_window; end
    def page_text_control
      @page_text ||= Struct.new(:text) { def style(**); end }.new
    end
    def text_controls
      @page_text = page_text_control
      @tashkeel_button = page_text_control
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
end
