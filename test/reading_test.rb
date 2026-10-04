# frozen_string_literal: true

require_relative "test_helper"

class ReadingTest < StoreTestCase
  class API
    attr_reader :calls
    attr_accessor :error

    def initialize(book, pages)
      @book, @pages, @calls = book, pages, []
    end

    def book(id)
      raise @error if @error

      @calls << [:book, id]
      @book
    end

    def page(file_id, number)
      raise @error if @error

      @calls << [:page, file_id, number]
      @pages.fetch(file_id).find { |page| page.fetch("number") == number }
    end
  end

  class HTTP
    attr_reader :calls
    def initialize = @calls = []
    def close; end
    def read_range(url, offset:, length:, **)
      @calls << url
      bytes = "%PDF-1.7\nfixture"
      Aljam3::HTTP::Range.new(bytes.byteslice(offset, length), bytes.bytesize, '"v1"', url)
    end
  end

  def setup
    super
    @api = API.new(book, { 10 => pages, 20 => pages(2) })
    @http = HTTP.new
    @downloader = Aljam3::Downloader.new(api: @api, store: @store, directory: File.join(@directory, "books"))
    @reading = Aljam3::Reading.new(api: @api, store: @store, downloader: @downloader, http: @http)
  end

  def teardown
    @reading.close
    super
  end

  def test_online_reading_uses_a_lazy_pdf_source_without_creating_an_offline_book
    opened = @reading.book(1)
    assert_equal 2, @reading.page(1, 10, 2).fetch("number")
    source = @reading.pdf_source(1, opened.fetch("files").first)
    assert_instance_of Aljam3::RemotePDF, source
    assert_empty @http.calls
    assert_equal "%PDF", source.read(0, 4)
    assert_empty @store.downloaded_ids
    assert_empty @store.search("العلم").fetch("pages")
    assert_empty @store.files(1)

    @reading.page(1, 10, 2)
    assert_same source, @reading.pdf_source(1, opened.fetch("files").first)
    assert_equal [[:book, 1], [:page, 10, 2]], @api.calls
    assert_equal 1, @http.calls.length
  end

  def test_downloaded_book_uses_local_pages_and_files_when_api_is_unreachable
    install_book
    @api.error = Aljam3::ConnectionError.new("Offline")
    assert_equal 10, @reading.book(1).fetch("files").first.fetch("id")
    assert_equal 101, @reading.page(1, 10, 2).fetch("id")
    assert_equal @downloader.pdf_path(1, 10), @reading.pdf_source(1, book.fetch("files").first)
    assert_empty @api.calls
    assert_empty @http.calls
  end

  def test_search_hit_resolves_the_exact_volume_instead_of_guessing_from_page_number
    volumes = book.merge("files" => [book.fetch("files").first, book(2).fetch("files").first])
    location = @reading.locate(volumes, { "id" => 201, "number" => 2 })
    assert_equal 20, location.fetch("file_id")
    assert_equal 201, location.fetch("id")
    assert_raises(Aljam3::ResponseError) { @reading.locate(volumes, { "id" => 999, "number" => 2 }) }
  end

  def test_search_hit_with_a_file_id_does_not_fetch_each_volume
    hit = { "id" => 201, "number" => 2, "file_id" => 20 }
    @api.error = Aljam3::ConnectionError.new("No volume lookup should be needed")

    assert_same hit, @reading.locate(book, hit)
    assert_empty @api.calls
  end

  def test_incomplete_download_cannot_supply_offline_reading
    install_book(1, complete: false)
    @api.error = Aljam3::ConnectionError.new("Offline")
    assert_raises(Aljam3::ConnectionError) { @reading.book(1) }
  end
end
