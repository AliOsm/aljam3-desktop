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
    def book(id, check: nil) = get("books/#{Integer(id)}", { "expand[]" => "files" }, check:)

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

    def each_page_batch(file_id, start: 1, check: nil)
      return enum_for(__method__, file_id, start:, check:) unless block_given?

      page = start
      while page
        response = get("files/#{Integer(file_id)}", { "expand[]" => "pages", "limit" => 500, "page" => page }, check:)
        yield response.fetch("pages")
        page = response.fetch("pagination").fetch("next_page")
      end
    end

    def each_category_book_batch(category_id, check: -> {})
      return enum_for(__method__, category_id, check:) unless block_given?

      page = 1
      while page
        check.call
        data = get("categories/#{Integer(category_id)}", { "expand[]" => "books", "limit" => 500, "page" => page }, check:)
        check.call
        raise ResponseError.new(502), "Unexpected category response." unless data.fetch("id") == category_id

        category = data.slice("id", "name", "books_count", "link")
        books = data.fetch("books").map { |book| book.merge("category" => category) }
        pagination = data.fetch("pagination")
        yield books, pagination.fetch("count")
        following = pagination.fetch("next_page")
        raise ResponseError.new(502), "Category pagination did not advance." if following && (!following.is_a?(Integer) || following <= page)

        page = following
      end
    end

    private

    def get(path, parameters = {}, check: nil, **keywords)
      parameters = parameters.merge(keywords)
      @lock.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        while @next_request > now
          check&.call
          sleep([@next_request - now, 0.05].min)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        @next_request = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @interval
      end
      check&.call
      query = URI.encode_www_form(parameters.compact)
      url = "#{@base_url}/api/v1/#{path}?#{query}"
      data = JSON.parse(check ? @http.get(url, check:) : @http.get(url))
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
      failure = ResponseError.new(502)
      Diagnostics.annotate(failure, **Diagnostics.request_context("#{@base_url}/api/v1/#{path}"))
      raise failure, "The library returned an invalid response."
    end
  end
end
