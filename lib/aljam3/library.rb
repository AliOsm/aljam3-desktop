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

    def authors(query: "", page: 1, downloaded: false)
      return Result.new(@store.authors(query:, page:, downloaded: true), :downloaded, nil) if downloaded

      data = @api.authors(query:, page:)
      @store.cache_authors(data.fetch("authors"))
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

    def search(query, category: nil, author: nil, library: nil, page: 1, book_id: nil, downloaded: false, order: "relevance", pool_size: Store::Search::POOL_SIZE)
      options = { category:, author:, library:, page:, book_id: }
      generation = @store.search_generation
      return Result.new(@store.search(query, **options, order:, pool_size:, generation:), :downloaded, nil) if downloaded

      data = @api.search(query, **options)
      @store.cache_books(data.fetch("pages").map { |hit| hit.fetch("book") }.uniq { |book| book.fetch("id") })
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.search(query, **options, order:, pool_size:, generation:), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.search(query, **options, order:, pool_size:, generation:), :local, error.status)
    end
  end
end
