# frozen_string_literal: true

require_relative "http"

module Aljam3
  class DownloadStopped < StandardError; end

  class Downloader
    def initialize(api:, store:, directory:, http: HTTP.new)
      @api, @store, @directory, @http = api, store, directory, http
      FileUtils.mkdir_p(directory)
    end

    def call(book_id, check: -> {})
      return @store.book(book_id) if @store.downloaded?(book_id)

      check.call
      book = @api.book(book_id)
      files = book.fetch("files")
      raise "This book has no downloadable files." if files.empty?

      previous = @store.files(book_id)
      staging = partial_directory(book_id)
      destination = File.join(@directory, Integer(book_id).to_s)
      if previous.any? && previous.map { |file| file.values_at("id", "pages_count") } != files.map { |file| file.values_at("id", "pages_count") }
        FileUtils.rm_rf(staging)
        FileUtils.rm_rf(destination)
      end
      @store.prepare_download(book, resume: true)
      # A crash after renaming but before committing can leave a complete directory.
      staging = destination if File.directory?(destination)
      FileUtils.mkdir_p(staging)
      files.each_with_index do |file, index|
        check.call
        path = File.join(staging, "#{file.fetch('id')}.pdf")
        unless File.file?(path)
          @http.download(file.fetch("urls").fetch("pdf"), path, resume: true, check:) do |bytes, total|
            fraction = total && total.positive? ? bytes.fdiv(total) * 0.7 : 0
            yield (index + fraction).fdiv(files.length), "تنزيل PDF · #{index + 1} / #{files.length}", bytes, total if block_given?
          end
        end
        count = @store.page_count(file.fetch("id"))
        if count < file.fetch("pages_count")
          @api.each_page_batch(file.fetch("id"), start: count / 500 + 1) do |pages|
            check.call
            @store.add_pages(file.fetch("id"), pages)
            count = @store.page_count(file.fetch("id"))
            fraction = 0.7 + 0.3 * count.fdiv(file.fetch("pages_count"))
            yield (index + fraction).fdiv(files.length), "حفظ النص · #{count} / #{file.fetch('pages_count')} صفحة", File.size(path), File.size(path) if block_given?
          end
        end
        raise ConnectionError, "The book's page count changed. Please retry the download." unless count == file.fetch("pages_count")
      end
      check.call
      File.rename(staging, destination) unless staging == destination
      @store.complete_download(book_id, bytes: files.sum { |file| File.size(File.join(destination, "#{file.fetch('id')}.pdf")) })
      book
    end

    def cancel(book_id)
      FileUtils.rm_rf(partial_directory(book_id))
      unless @store.downloaded?(book_id)
        FileUtils.rm_rf(File.join(@directory, Integer(book_id).to_s))
        @store.discard_download(book_id)
      end
    end

    def remove(book_id)
      path = File.join(@directory, Integer(book_id).to_s)
      FileUtils.remove_entry(path) if File.directory?(path)
      cancel(book_id)
      @store.discard_download(book_id)
    end

    def disk_usage(book_id = nil)
      directories = book_id ? [File.join(@directory, Integer(book_id).to_s), partial_directory(book_id)] : [@directory]
      directories.sum do |directory|
        Dir.glob(File.join(directory, "**/*"), File::FNM_DOTMATCH).sum { |path| File.file?(path) ? File.size(path) : 0 }
      end
    end

    def pdf_path(book_id, file_id) = File.join(@directory, Integer(book_id).to_s, "#{Integer(file_id)}.pdf")

    private

    def partial_directory(book_id) = File.join(@directory, ".partial", Integer(book_id).to_s)
  end
end
