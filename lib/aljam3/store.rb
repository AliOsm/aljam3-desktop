# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "time"
require_relative "text"

module Aljam3
  class Store
    PAGE_SIZE = 12

    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      extension = ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION") do
        suffix = RUBY_PLATFORM.match?(/mingw|mswin/) ? "dll" : "so"
        File.expand_path("../../vendor/tokenizer/sqlite_tokenizer_ar.#{suffix}", __dir__)
      end
      @db = SQLite3::Database.new(path, results_as_hash: true, extensions: [extension])
      @db.busy_timeout = 5_000
      @lock = Mutex.new
      @db.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")
      migrate
    rescue StandardError
      @db&.close
      raise
    end

    def close = @lock.synchronize { @db.close }

    def cache_books(books)
      @lock.synchronize do
        @db.transaction do
          books.each do |book|
            @db.execute(<<~SQL, [book.fetch("id"), Text.plain(book.fetch("title")), Text.normalize(Text.plain(book.fetch("title"))), book.dig("category", "id"), JSON.generate(book)])
              INSERT INTO books(id, title, search_title, category_id, data) VALUES (?, ?, ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET title=excluded.title, search_title=excluded.search_title,
                category_id=excluded.category_id, data=excluded.data
            SQL
          end
        end
      end
    end

    def book(id)
      @lock.synchronize do
        row = @db.get_first_row("SELECT data FROM books WHERE id = ?", [id])
        JSON.parse(row.fetch("data")) if row
      end
    end

    def downloaded?(id)
      @lock.synchronize { !!@db.get_first_value("SELECT 1 FROM books WHERE id = ? AND downloaded_at IS NOT NULL", [id]) }
    end

    def downloaded_ids
      @lock.synchronize { @db.execute("SELECT id FROM books WHERE downloaded_at IS NOT NULL").map { |row| row.fetch("id") } }
    end

    def catalog(query: "", category: nil, page: 1, downloaded: false)
      where = ["search_title LIKE ? ESCAPE '\\'"]
      terms = ["%#{Text.normalize(query).gsub(/[\\%_]/) { |char| "\\#{char}" }}%"]
      where << "downloaded_at IS NOT NULL" if downloaded
      if category
        where << "category_id = ?"
        terms << category
      end
      @lock.synchronize do
        count = @db.get_first_value("SELECT count(*) FROM books WHERE #{where.join(' AND ')}", terms)
        rows = @db.execute("SELECT data FROM books WHERE #{where.join(' AND ')} ORDER BY title LIMIT ? OFFSET ?", [*terms, PAGE_SIZE, (page - 1) * PAGE_SIZE])
        { "books" => rows.map { |row| JSON.parse(row.fetch("data")) }, "pagination" => pagination(count, page) }
      end
    end

    def search(query, page: 1, category: nil, book_id: nil)
      match = Text.match_query(query)
      return { "pages" => [], "pagination" => pagination(0, page) } if match.empty?

      joins = "FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid JOIN files f ON f.id = p.file_id JOIN books b ON b.id = f.book_id"
      conditions = "WHERE pages_fts MATCH ? AND b.downloaded_at IS NOT NULL"
      terms = [match]
      if category
        conditions += " AND b.category_id = ?"
        terms << category
      end
      if book_id
        conditions += " AND b.id = ?"
        terms << book_id
      end
      @lock.synchronize do
        count = @db.get_first_value("SELECT count(*) #{joins} #{conditions}", terms)
        rows = @db.execute("SELECT p.id, p.file_id, p.number, p.content, snippet(pages_fts, 0, '', '', '…', 42) AS excerpt, b.data #{joins} #{conditions} ORDER BY rank, p.id LIMIT ? OFFSET ?", [*terms, PAGE_SIZE, (page - 1) * PAGE_SIZE])
        pages = rows.map { |row| row.reject { |key, _| key == "data" }.merge("book" => JSON.parse(row.fetch("data"))) }
        { "pages" => pages, "pagination" => pagination(count, page) }
      end
    end

    def prepare_download(book)
      cache_books([book])
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
      @lock.synchronize do
        @db.transaction do
          @db.prepare("INSERT INTO pages(id, file_id, number, content) VALUES (?, ?, ?, ?)") do |statement|
            pages.each { |page| statement.execute(page.fetch("id"), file_id, page.fetch("number"), page.fetch("content")) }
          end
        end
      end
    end

    def complete_download(id)
      @lock.synchronize { @db.execute("UPDATE books SET downloaded_at = ? WHERE id = ?", [Time.now.utc.iso8601, id]) }
    end

    def discard_download(id)
      @lock.synchronize do
        @db.transaction do
          @db.execute("DELETE FROM files WHERE book_id = ?", [id])
          @db.execute("UPDATE books SET downloaded_at = NULL WHERE id = ?", [id])
        end
      end
    end

    def files(book_id)
      @lock.synchronize { @db.execute("SELECT data FROM files WHERE book_id = ? ORDER BY position", [book_id]).map { |row| JSON.parse(row.fetch("data")) } }
    end

    def page(file_id, number)
      @lock.synchronize { @db.get_first_row("SELECT id, file_id, number, content FROM pages WHERE file_id = ? AND number = ?", [file_id, number]) }
    end

    def find_page(id)
      @lock.synchronize { @db.get_first_row("SELECT id, file_id, number, content FROM pages WHERE id = ?", [id]) }
    end

    def preference(key, default = nil)
      @lock.synchronize do
        value = @db.get_first_value("SELECT value FROM preferences WHERE key = ?", [key])
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
      @db.transaction(:immediate) do
        schema = case @db.get_first_value("PRAGMA user_version")
                 when 0 then "schema.sql"
                 when 1 then "migrations/002_arabic_search.sql"
                 when 2 then next
                 else raise "This library was created by a newer version of Aljam3 Desktop."
                 end
        @db.execute_batch(File.read(File.join(__dir__, schema)))
      end
    end

    def pagination(count, page)
      { "count" => count, "current_page" => page, "total_pages" => [(count.to_f / PAGE_SIZE).ceil, 1].max }
    end
  end
end
