# frozen_string_literal: true

require_relative "api"
require_relative "store"

module Aljam3
  Result = Data.define(:data, :source, :notice)

  class Library
    def initialize(api:, store:)
      @api, @store = api, store
    end

    def categories
      categories = @api.categories
      @store.save_preference("categories", categories)
      categories
    rescue ConnectionError, ResponseError
      @store.preference("categories", [])
    end

    def libraries
      libraries = @api.libraries
      @store.save_preference("libraries", libraries)
      libraries
    rescue ConnectionError, ResponseError
      @store.preference("libraries", [])
    end

    def authors(query: "", page: 1)
      data = @api.authors(query:, page:)
      cached = @store.preference("authors", [])
      @store.save_preference("authors", (data.fetch("authors") + cached).uniq { |author| author.fetch("id") }.first(1000))
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.authors(query:, page:), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.authors(query:, page:), :local, error.status)
    end

    def browse(query: "", category: nil, author: nil, library: nil, page: 1, downloaded: false)
      options = { query:, category:, author:, library:, page: }
      return Result.new(@store.catalog(**options, downloaded: true), :downloaded, nil) if downloaded

      data = @api.books(**options)
      @store.cache_books(data.fetch("books"))
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.catalog(**options, downloaded: !query.strip.empty?), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.catalog(**options, downloaded: !query.strip.empty?), :local, error.status)
    end

    def search(query, category: nil, author: nil, library: nil, page: 1, book_id: nil)
      options = { category:, author:, library:, page:, book_id: }
      data = @api.search(query, **options)
      @store.cache_books(data.fetch("pages").map { |hit| hit.fetch("book") }.uniq { |book| book.fetch("id") })
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.search(query, **options), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.search(query, **options), :local, error.status)
    end
  end
end
