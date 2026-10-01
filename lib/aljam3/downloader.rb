# frozen_string_literal: true

require "tmpdir"
require_relative "http"

module Aljam3
  class Downloader
    def initialize(api:, store:, directory:, http: HTTP.new)
      @api, @store, @directory, @http = api, store, directory, http
      FileUtils.mkdir_p(directory)
    end

    def call(book_id)
      return @store.book(book_id) if @store.downloaded?(book_id)

      book = @api.book(book_id)
      files = book.fetch("files")
      raise "This book has no downloadable files." if files.empty?

      @store.prepare_download(book)
      temporary = Dir.mktmpdir(".download-", @directory)
      files.each_with_index do |file, index|
        yield index.fdiv(files.length), "تنزيل PDF · #{index + 1} / #{files.length}" if block_given?
        @http.download(file.fetch("urls").fetch("pdf"), File.join(temporary, "#{file.fetch('id')}.pdf")) do |bytes, total|
          fraction = total && total.positive? ? bytes.fdiv(total) * 0.8 : 0
          yield (index + fraction).fdiv(files.length), "تنزيل PDF · #{(bytes / 1_048_576.0).round(1)} MB" if block_given?
        end
        count = 0
        @api.each_page_batch(file.fetch("id")) do |pages|
          @store.add_pages(file.fetch("id"), pages)
          count += pages.length
          yield (index + 0.9).fdiv(files.length), "فهرسة النص · #{count} صفحة" if block_given?
        end
        raise ConnectionError, "The book's page count changed. Please retry the download." unless count == file.fetch("pages_count")
      end
      destination = File.join(@directory, Integer(book_id).to_s)
      FileUtils.rm_rf(destination) if File.directory?(destination)
      File.rename(temporary, destination)
      @store.complete_download(book_id)
      book
    rescue StandardError
      @store.discard_download(book_id) unless @store.downloaded?(book_id)
      raise
    ensure
      FileUtils.rm_rf(temporary) if temporary
    end

    def pdf_path(book_id, file_id)
      File.join(@directory, Integer(book_id).to_s, "#{Integer(file_id)}.pdf")
    end
  end
end
