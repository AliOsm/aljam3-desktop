# frozen_string_literal: true

require_relative "test_helper"

class LibraryTest < StoreTestCase
  class API
    attr_accessor :error, :response
    attr_reader :calls

    def initialize
      @calls = []
    end

    def search(query, **options)
      @calls << [query, options]
      raise @error if @error

      @response
    end

    def books(**options) = search(options.fetch(:query), **options)
  end

  def setup
    super
    install_book
    @api = API.new
    @api.response = { "pages" => [], "pagination" => { "count" => 0 } }
    @library = Aljam3::Library.new(api: @api, store: @store)
  end

  def test_online_search_uses_api_even_when_local_results_exist
    result = @library.search("العلم", category: 2, page: 3)
    assert_equal :online, result.source
    assert_empty result.data.fetch("pages")
    assert_equal [["العلم", { category: 2, author: nil, library: nil, page: 3, book_id: nil }]], @api.calls
  end

  def test_explicit_downloaded_scope_never_calls_the_api
    @store.cache_books([book(2)])
    result = @library.search("العلم", downloaded: true)
    assert_equal :downloaded, result.source
    assert_equal [1], result.data.fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    result = @library.browse(downloaded: true)
    assert_equal [1], result.data.fetch("books").map { |entry| entry.fetch("id") }
    assert_equal [4], @library.authors(downloaded: true).data.fetch("authors").map { |author| author.fetch("id") }
    assert_empty @api.calls
  end

  def test_connection_failure_searches_downloaded_books_and_next_search_retries_api
    @api.error = Aljam3::ConnectionError.new("No route to host")
    result = @library.search("العلم")
    assert_equal :offline, result.source
    assert_equal 2, result.data.fetch("pages").length
    @api.error = nil
    assert_equal :online, @library.search("العلم").source
    assert_equal 2, @api.calls.length
  end

  def test_service_failure_is_distinguished_from_no_internet
    @api.error = Aljam3::ResponseError.new(429)
    result = @library.search("العلم")
    assert_equal :local, result.source
    assert_equal 429, result.notice
    assert_equal 2, result.data.fetch("pages").length
  end

  def test_book_search_keeps_its_scope_online_and_offline
    install_book(2)
    assert_equal :online, @library.search("العلم", book_id: 2).source
    assert_equal 2, @api.calls.last.last.fetch(:book_id)
    @api.error = Aljam3::ConnectionError.new("Offline")
    result = @library.search("العلم", book_id: 2)
    assert_equal :offline, result.source
    assert_equal [2], result.data.fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    assert_equal 2, result.data.fetch("pagination").fetch("count")
    assert_empty @library.search("العلم", book_id: 3).data.fetch("pages")
  end

  def test_offline_title_search_only_includes_downloaded_books
    @store.cache_books([book(2)])
    @api.error = Aljam3::ConnectionError.new("Offline")
    result = @library.browse(query: "اداب")
    assert_equal :offline, result.source
    assert_equal [1], result.data.fetch("books").map { |item| item.fetch("id") }
    assert_equal 2, @library.browse.data.fetch("books").length
  end

  def test_all_text_filters_are_preserved_when_falling_back_to_sqlite
    other = book(2).merge("author" => { "id" => 8, "name" => "مؤلف آخر" })
    @store.prepare_download(other)
    @store.add_pages(20, pages(2))
    @store.complete_download(2)
    @api.error = Aljam3::ConnectionError.new("Offline")

    result = @library.search("العلم", category: 2, author: 4, library: 3)
    assert_equal [1], result.data.fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    assert_empty @library.search("العلم", category: 2, author: 4, library: 9).data.fetch("pages")
    assert_equal [2], @library.browse(author: 8).data.fetch("books").map { |item| item.fetch("id") }
  end
end
