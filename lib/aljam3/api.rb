# frozen_string_literal: true

require "json"
require_relative "http"

module Aljam3
  class API
    def initialize(base_url: "https://aljam3.com", http: HTTP.new, interval: 1.05)
      @base_url = base_url.delete_suffix("/")
      @http = http
      @interval = interval
      @lock = Mutex.new
      @next_request = 0
    end

    def categories = get("categories").fetch("categories")
    def book(id) = get("books/#{Integer(id)}", "expand[]" => "files")

    def books(query: "", category: nil, page: 1)
      path = category ? "categories/#{Integer(category)}" : "books"
      get(path, "q" => query, "page" => page, "limit" => 12, "expand[]" => "books")
    end

    def search(query, page: 1, category: nil, book_id: nil)
      get("search", "q" => query, "page" => page, "limit" => 12, "categories[]" => category, "books[]" => book_id)
    end

    def each_page_batch(file_id)
      return enum_for(__method__, file_id) unless block_given?

      page = 1
      while page
        response = get("files/#{Integer(file_id)}", "expand[]" => "pages", "limit" => 500, "page" => page)
        yield response.fetch("pages")
        page = response.fetch("pagination").fetch("next_page")
      end
    end

    private

    def get(path, parameters = {})
      @lock.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep(@next_request - now) if @next_request > now
        @next_request = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @interval
      end
      query = URI.encode_www_form(parameters.compact)
      JSON.parse(@http.get("#{@base_url}/api/v1/#{path}?#{query}"))
    rescue JSON::ParserError
      raise ResponseError.new(502), "The library returned an invalid response."
    end
  end
end
