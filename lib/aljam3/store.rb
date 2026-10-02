# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "time"
require "set"
require_relative "text"
require_relative "store/reading"
require_relative "store/downloads"
require_relative "store/connection"
require_relative "store/worker"
require_relative "store/search"

module Aljam3
  class Store
    include Reading, Downloads
    PAGE_SIZE = 12

    def initialize(path, background: true)
      @path = File.expand_path(path)
      FileUtils.mkdir_p(File.dirname(path))
      extension = ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION") do
        suffix = RUBY_PLATFORM.match?(/mingw|mswin/) ? "dll" : "so"
        File.expand_path("../../vendor/tokenizer/sqlite_tokenizer_ar.#{suffix}", __dir__)
      end
      @db = SQLite3::Database.new(path, results_as_hash: true, extensions: [extension])
      @db.busy_handler_timeout = 5_000
      @lock = Mutex.new
      # Larger pages pack OCR text more tightly. Existing libraries retain their
      # page size; changing it would require a complete VACUUM of user data.
      @db.execute("PRAGMA page_size = 16384") if @db.get_first_value("PRAGMA user_version").zero?
      @db.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA cache_size = -8192;")
      migrate
      @reader = Connection.new(path, extension:, readonly: true)
      @queries, @indexer = Array.new(2) { Worker.new(@path) } if background
    rescue StandardError
      @db&.close
      raise
    end

    def close
      @queries&.close
      @indexer&.close
      @reader&.close
      @lock.synchronize { @db.close }
    end

    def cache_books(books)
      @lock.synchronize do
        @db.transaction do
          write_authors(books.filter_map { |book| book["author"] }.uniq { |author| author.fetch("id") })
          books.each do |book|
            @db.execute(<<~SQL, [book.fetch("id"), Text.plain(book.fetch("title")), Text.normalize(Text.plain(book.fetch("title"))), book.dig("category", "id"), JSON.generate(book)])
              INSERT INTO books(id, title, search_title, category_id, data) VALUES (?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET title=excluded.title, search_title=excluded.search_title,
                category_id=excluded.category_id, data=json_patch(books.data, excluded.data)
            SQL
          end
        end
      end
    end

    def book(id)
      @reader.call do |db|
        row = db.get_first_row("SELECT data FROM books WHERE id = ?", [id])
        JSON.parse(row.fetch("data")) if row
      end
    end

    def downloaded?(id)
      @reader.call { |db| !!db.get_first_value("SELECT 1 FROM books WHERE id = ? AND downloaded_at IS NOT NULL", [id]) }
    end

    def downloaded_ids
      @reader.call { |db| db.execute("SELECT id FROM books WHERE downloaded_at IS NOT NULL").map { |row| row.fetch("id") }.to_set }
    end

    def catalog(query: "", category: nil, author: nil, library: nil, page: 1, downloaded: false)
      where, terms = [], []
      unless query.empty?
        where << "search_title LIKE ? ESCAPE '\\'"
        terms << "%#{Text.normalize(query).gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
      end
      where << "downloaded_at IS NOT NULL" if downloaded
      if category
        where << "category_id = ?"
        terms << category
      end
      { author:, library: }.compact.each do |key, value|
        where << "#{key}_id = ?"
        terms << value
      end
      condition = where.empty? ? "" : "WHERE #{where.join(' AND ')}"
      @reader.call do |db|
        count = db.get_first_value("SELECT count(*) FROM books #{condition}", terms)
        rows = db.execute("SELECT data FROM books #{condition} ORDER BY title, id LIMIT ? OFFSET ?", [*terms, PAGE_SIZE, (page - 1) * PAGE_SIZE])
        { "books" => rows.map { |row| JSON.parse(row.fetch("data")) }, "pagination" => pagination(count, page) }
      end
    end

    def authors(query: "", page: 1, downloaded: false)
      terms, conditions = [], []
      unless query.strip.empty?
        conditions << "a.search_name LIKE ? ESCAPE '\\'"
        terms << "%#{Text.normalize(query).gsub(/[\\%_]/) { |char| "\\#{char}" }}%"
      end
      conditions << "EXISTS (SELECT 1 FROM books b WHERE b.author_id = a.id AND b.downloaded_at IS NOT NULL)" if downloaded
      where = conditions.empty? ? "" : "WHERE #{conditions.join(' AND ')}"
      @reader.call do |db|
        count = db.get_first_value("SELECT count(*) FROM authors a #{where}", terms)
        rows = db.execute("SELECT data FROM authors a #{where} ORDER BY name, id LIMIT ? OFFSET ?", [*terms, PAGE_SIZE, (page - 1) * PAGE_SIZE])
        { "authors" => rows.map { |row| JSON.parse(row.fetch("data")) }, "pagination" => pagination(count, page) }
      end
    end

    def cache_authors(authors)
      @lock.synchronize { @db.transaction { write_authors(authors) } }
    end

    def search(query, **options)
      return @queries.call(:search, query, **options) if @queries

      @reader.call { |db| db.transaction { (@search ||= Search.new(db)).call(query, **options) } }
    end

    def cancel_search = @queries&.cancel

    def database_bytes = [@path, "#{@path}-wal", "#{@path}-shm"].sum { |path| File.size?(path) || 0 }

    def prepare_download(book, resume: false)
      return @indexer.call(:prepare_download, book, resume:) if @indexer

      cache_books([book])
      existing = files(book.fetch("id"))
      return if resume && existing.map { |file| file.values_at("id", "pages_count") } == book.fetch("files").map { |file| file.values_at("id", "pages_count") }

      @lock.synchronize do
        @db.transaction do
          @db.execute("DELETE FROM files WHERE book_id = ?", [book.fetch("id")])
          book.fetch("files").each_with_index do |file, position|
            @db.execute("INSERT INTO files(id, book_id, position, data) VALUES (?, ?, ?, ?)", [file.fetch("id"), book.fetch("id"), position, JSON.generate(file)])
          end
        end
      end
    end

    def add_pages(file_id, pages)
      return @indexer.call(:add_pages, file_id, pages) if @indexer

      @lock.synchronize do
        @db.transaction do
          @db.prepare("INSERT OR IGNORE INTO pages(id, file_id, number, content) VALUES (?, ?, ?, ?)") do |statement|
            pages.each { |page| statement.execute(page.fetch("id"), file_id, page.fetch("number"), page.fetch("content")) }
          end
          unless pages.empty?
            first, last = pages.map { |page| page.fetch("id") }.minmax
            @db.execute("UPDATE files SET first_page_id = min(coalesce(first_page_id, ?), ?), last_page_id = max(coalesce(last_page_id, ?), ?) WHERE id = ?", [first, first, last, last, file_id])
          end
        end
      end
    end

    def complete_download(id, bytes: nil)
      @lock.synchronize { @db.execute("UPDATE books SET downloaded_at = ?, download_bytes = ? WHERE id = ?", [Time.now.utc.iso8601, bytes, id]) }
    end

    def discard_download(id)
      return @indexer.call(:discard_download, id) if @indexer

      @lock.synchronize do
        @db.transaction do
          @db.execute("DELETE FROM files WHERE book_id = ?", [id])
          @db.execute("UPDATE books SET downloaded_at = NULL, download_bytes = NULL WHERE id = ?", [id])
        end
      end
    end

    def files(book_id)
      @reader.call { |db| db.execute("SELECT data FROM files WHERE book_id = ? ORDER BY position", [book_id]).map { |row| JSON.parse(row.fetch("data")) } }
    end

    def page(file_id, number)
      @reader.call { |db| db.get_first_row("SELECT id, file_id, number, content FROM pages WHERE file_id = ? AND number = ?", [file_id, number]) }
    end

    def find_page(id)
      @reader.call { |db| db.get_first_row("SELECT id, file_id, number, content FROM pages WHERE id = ?", [id]) }
    end

    def preference(key, default = nil)
      @reader.call do |db|
        value = db.get_first_value("SELECT value FROM preferences WHERE key = ?", [key])
        value ? JSON.parse(value) : default
      end
    end

    def save_preference(key, value)
      @lock.synchronize do
        @db.execute("INSERT INTO preferences(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, JSON.generate(value)])
      end
    end

    private

    def migrate
      version = @db.get_first_value("PRAGMA user_version")
      raise "This library was created by a newer version of Aljam3 Desktop." if version > 4
      return if version == 4

      @db.transaction(:immediate) do
        version = @db.get_first_value("PRAGMA user_version")
        next if version == 4

        @db.execute_batch(File.read(File.join(__dir__, "schema.sql"))) if version.zero?
        @db.execute_batch(File.read(File.join(__dir__, "migrations/002_arabic_search.sql"))) if version == 1
        @db.execute_batch(File.read(File.join(__dir__, "migrations/003_reading_and_downloads.sql"))) if version < 3
        if version < 4
          @db.execute_batch(File.read(File.join(__dir__, "migrations/004_large_library.sql")))
          @db.execute_batch(File.read(File.join(__dir__, "migrations/004_prefix_search.sql"))) if version.between?(2, 3)
          rows = @db.execute("SELECT DISTINCT json_extract(data, '$.author') AS data FROM books WHERE author_id IS NOT NULL")
          write_authors(rows.map { |row| JSON.parse(row.fetch("data")) })
          cached = @db.get_first_value("SELECT value FROM preferences WHERE key = 'authors'")
          write_authors(JSON.parse(cached)) if cached
        end
      end
    end

    def write_authors(authors)
      authors.each do |author|
        name = Text.plain(author.fetch("name"))
        @db.execute(<<~SQL, [author.fetch("id"), name, Text.normalize(name), JSON.generate(author)])
          INSERT INTO authors VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name, search_name=excluded.search_name, data=excluded.data
        SQL
      end
    end

    def pagination(count, page)
      { "count" => count, "current_page" => page, "total_pages" => [(count.to_f / PAGE_SIZE).ceil, 1].max }
    end
  end
end
