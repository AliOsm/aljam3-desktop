# frozen_string_literal: true

require "tmpdir"
require_relative "http"

module Aljam3
  # Online reading never changes the downloaded library or its search index.
  # PDFs are fetched per volume; page text is fetched on demand.
  class Reading
    def initialize(api:, store:, downloader:, http: HTTP.new)
      @api, @store, @downloader, @http = api, store, downloader, http
      @directory = Dir.mktmpdir("aljam3-reading-")
      @pages = {}
      @lock = Mutex.new
    end

    def close = FileUtils.remove_entry(@directory)

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

      # Search responses omit the file ID. Verify the page ID in each possible
      # volume instead of guessing from the page number or database ID.
      book.fetch("files").each do |file|
        next if file.fetch("pages_count") < hit.fetch("number")

        candidate = page(book.fetch("id"), file.fetch("id"), hit.fetch("number"))
        return candidate if candidate.fetch("id") == hit.fetch("id")
      end
      raise ResponseError.new(404), "The search page could not be found in this book."
    end

    def pdf_path(book_id, file)
      return @downloader.pdf_path(book_id, file.fetch("id")) if @store.downloaded?(book_id)

      path = File.join(@directory, "#{Integer(file.fetch('id'))}.pdf")
      @http.download(file.fetch("urls").fetch("pdf"), path) unless File.file?(path)
      FileUtils.touch(path)
      Dir.glob(File.join(@directory, "*.pdf")).sort_by { |pdf| File.mtime(pdf) }.reverse.drop(3).each { |pdf| File.delete(pdf) }
      path
    end
  end
end
