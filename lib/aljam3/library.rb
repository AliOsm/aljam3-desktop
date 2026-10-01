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

    def browse(query: "", category: nil, page: 1, downloaded: false)
      return Result.new(@store.catalog(query:, category:, page:, downloaded: true), :downloaded, nil) if downloaded

      data = @api.books(query:, category:, page:)
      @store.cache_books(data.fetch("books"))
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.catalog(query:, category:, page:, downloaded: !query.strip.empty?), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.catalog(query:, category:, page:, downloaded: !query.strip.empty?), :local, error.status)
    end

    def search(query, category: nil, page: 1, book_id: nil)
      data = @api.search(query, category:, page:, book_id:)
      @store.cache_books(data.fetch("pages").map { |hit| hit.fetch("book") }.uniq { |book| book.fetch("id") })
      Result.new(data, :online, nil)
    rescue ConnectionError
      Result.new(@store.search(query, category:, page:, book_id:), :offline, :connection)
    rescue ResponseError => error
      Result.new(@store.search(query, category:, page:, book_id:), :local, error.status)
    end
  end
end
