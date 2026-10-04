# frozen_string_literal: true
require_relative "test_helper"

class ApiFiltersTest < Minitest::Test
  class HTTP
    attr_accessor :response
    attr_reader :url
    def get(url)
      @url = URI(url)
      JSON.generate(@response)
    end
  end

  def setup
    @http = HTTP.new
    @api = Aljam3::API.new(http: @http, interval: 0)
  end

  def test_combined_title_filters_and_pagination_are_sent_to_the_server
    @http.response = { "filters" => { "author" => 4, "category" => 2 }, "books" => [] }
    assert_equal @http.response, @api.books(query: "العلم", author: 4, category: 2, page: 3)
    assert_equal "/api/v1/books", @http.url.path
    assert_equal({ "q" => "العلم", "author" => "4", "category" => "2", "page" => "3", "limit" => "12" }, URI.decode_www_form(@http.url.query).to_h)
  end

  def test_old_servers_cannot_silently_drop_the_requested_filters
    @http.response = { "books" => [{ "id" => 999 }] }
    error = assert_raises(Aljam3::ResponseError) { @api.books(author: 4, category: 2) }
    assert_equal 501, error.status
    @http.response["filters"] = { "author" => 4 }
    assert_raises(Aljam3::ResponseError) { @api.books(author: 4, category: 2) }
  end

  def test_single_scope_remains_compatible_with_the_existing_api
    @http.response = { "id" => 4, "name" => "النووي", "books" => [{ "id" => 1 }] }
    result = @api.books(author: 4)
    assert_equal "/api/v1/authors/4", @http.url.path
    assert_equal({ "id" => 4, "name" => "النووي" }, result.fetch("books").first.fetch("author"))
  end
end
