# frozen_string_literal: true

require "json"
require_relative "http"

module Aljam3
  class API
    attr_reader :connection
    def initialize(base_url: "https://aljam3.com", http: HTTP.new, interval: 1.05)
      @base_url = base_url.delete_suffix("/")
      @http = http
      @interval = interval
      @lock = Mutex.new
      @next_request = 0
      @connection = :checking
    end

    def categories = get("categories").fetch("categories")
    def libraries = get("libraries").fetch("libraries")
    def book(id) = get("books/#{Integer(id)}", "expand[]" => "files")

    def authors(query: "", page: 1)
      get("authors", "q" => query, "page" => page, "limit" => 20)
    end

    def books(query: "", category: nil, author: nil, library: nil, page: 1)
      scopes = { categories: category, authors: author, libraries: library }.compact
      if scopes.length > 1
        filters = { "category" => category, "author" => author, "library" => library }.compact.transform_values { |id| Integer(id) }
        data = get("books", filters.merge("q" => query, "page" => page, "limit" => 12))
        # Older servers ignored unknown parameters. Never display a broader result set.
        unless data["filters"] == filters
          raise ResponseError.new(501), "The server does not support combined title filters."
        end
        return data
      end

      path = scopes.empty? ? "books" : "#{scopes.keys.first}/#{Integer(scopes.values.first)}"
      data = get(path, "q" => query, "page" => page, "limit" => 12, "expand[]" => "books")
      unless scopes.empty?
        key = { categories: "category", authors: "author", libraries: "library" }.fetch(scopes.keys.first)
        data.fetch("books").each { |book| book[key] = data.slice("id", "name", "books_count", "link") }
      end
      data
    end

    def search(query, page: 1, category: nil, author: nil, library: nil, book_id: nil)
      get("search", "q" => query, "page" => page, "limit" => 12,
        "categories[]" => category, "authors[]" => author, "library" => library, "books[]" => book_id)
    end

    def page(file_id, number)
      get("files/#{Integer(file_id)}", "expand[]" => "pages", "limit" => 1, "page" => Integer(number)).fetch("pages").first
    end

    def each_page_batch(file_id, start: 1)
      return enum_for(__method__, file_id, start:) unless block_given?

      page = start
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
      data = JSON.parse(@http.get("#{@base_url}/api/v1/#{path}?#{query}"))
      @connection = :online
      data
    rescue ConnectionError
      @connection = :offline
      raise
    rescue ResponseError
      @connection = :unavailable
      raise
    rescue JSON::ParserError
      @connection = :unavailable
      raise ResponseError.new(502), "The library returned an invalid response."
    end
  end
end
