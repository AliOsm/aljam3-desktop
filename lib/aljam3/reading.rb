# frozen_string_literal: true

require_relative "remote_pdf"

module Aljam3
  # Online reading never changes the downloaded library or its search index.
  # PDF sections and page text are fetched on demand.
  class Reading
    def initialize(api:, store:, downloader:, http: HTTP.new)
      @api, @store, @downloader, @http = api, store, downloader, http
      @pages, @pdfs = {}, {}
      @lock = Mutex.new
    end

    def close
      @http.close
      @pages.clear
      @pdfs.clear
    end

    def book(id)
      return @store.book(id).merge("files" => @store.files(id)) if @store.downloaded?(id)

      book = @api.book(id)
      @store.cache_books([book])
      book
    end

    def page(book_id, file_id, number)
      return @store.page(file_id, number) if @store.downloaded?(book_id)

      @lock.synchronize do
        key = [file_id, number]
        return @pages.fetch(key) if @pages.key?(key)

        value = @api.page(file_id, number)
        raise ResponseError.new(404), "This page is unavailable." unless value && value.fetch("number") == number

        @pages.shift if @pages.size >= 50
        @pages[key] = value.merge("file_id" => file_id)
      end
    end

    def locate(book, hit)
      return hit if hit["file_id"]
      return @store.find_page(hit.fetch("id")) if @store.downloaded?(book.fetch("id"))

      # Older API responses omit the file ID. Verify the page ID in each possible
      # volume instead of guessing from the page number or database ID.
      book.fetch("files").each do |file|
        next if file.fetch("pages_count") < hit.fetch("number")

        candidate = page(book.fetch("id"), file.fetch("id"), hit.fetch("number"))
        return candidate if candidate.fetch("id") == hit.fetch("id")
      end
      raise ResponseError.new(404), "The search page could not be found in this book."
    end

    def pdf_source(book_id, file)
      return @downloader.pdf_path(book_id, file.fetch("id")) if @store.downloaded?(book_id)

      url = file.fetch("urls").fetch("pdf")
      source = @pdfs.delete(url) || RemotePDF.new(url, http: @http)
      @pdfs[url] = source
      @pdfs.shift if @pdfs.size > 3
      source
    end
  end
end
