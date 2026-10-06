# frozen_string_literal: true

module Aljam3
  class Store
    module Downloads
      def downloads(page: 1, filter: :all, ungrouped: false, category_id: nil, offset: nil, limit: PAGE_SIZE)
        @reader.call do |db|
          rows = db.execute(<<~SQL, [limit, offset || ([page.to_i, 1].max - 1) * PAGE_SIZE])
            WITH wanted AS MATERIALIZED (
              SELECT * FROM (#{download_selection(filter, ungrouped:, category_id:)})
              ORDER BY completed, queued_at, book_id LIMIT ? OFFSET ?
            )
            SELECT b.id AS book_id, b.data, b.download_bytes, d.state, d.details, b.downloaded_at
            FROM wanted w JOIN books b ON b.id = w.book_id LEFT JOIN downloads d ON d.book_id = b.id
            ORDER BY w.completed, w.queued_at, w.book_id
          SQL
          rows.to_h { |row| [row.fetch("book_id"), download_details(row)] }
        end
      end

      def download(id)
        @reader.call do |db|
          row = db.get_first_row(<<~SQL, [id])
            SELECT b.id AS book_id, b.data, b.download_bytes, d.state, d.details, b.downloaded_at
            FROM books b LEFT JOIN downloads d ON d.book_id = b.id
            WHERE b.id = ? AND (d.book_id IS NOT NULL OR b.downloaded_at IS NOT NULL)
          SQL
          download_details(row) if row
        end
      end

      def download_count(filter: :all, ungrouped: false, category_id: nil)
        @reader.call do |db|
          db.get_first_value("SELECT count(*) FROM (#{download_selection(filter, ungrouped:, category_id:)})")
        end
      end

      def download_state_counts
        @reader.call do |db|
          db.execute("SELECT state, count(*) AS count FROM downloads WHERE state != 'done' GROUP BY state")
            .to_h { |row| [row.fetch("state").to_sym, row.fetch("count")] }
        end
      end

      def download_bytes
        @reader.call do |db|
          db.get_first_value(<<~SQL)
            SELECT CASE WHEN count(*) = count(download_bytes) THEN coalesce(sum(download_bytes), 0) END
            FROM books INDEXED BY books_downloaded WHERE downloaded_at IS NOT NULL
          SQL
        end
      end

      def downloads_without_size(after: 0, limit: 100)
        @reader.call do |db|
          db.execute(<<~SQL, [after, limit])
            SELECT id, downloaded_at FROM books
            WHERE downloaded_at IS NOT NULL AND download_bytes IS NULL AND id > ?
            ORDER BY id LIMIT ?
          SQL
        end
      end

      def save_download_size(id, downloaded_at:, bytes:)
        @lock.synchronize do
          @db.execute(<<~SQL, [bytes, id, downloaded_at])
            UPDATE books SET download_bytes = ?
            WHERE id = ? AND downloaded_at = ? AND download_bytes IS NULL
          SQL
        end
      end

      def next_download
        @reader.call { |db| db.get_first_value("SELECT book_id FROM downloads WHERE state = 'queued' ORDER BY queued_at, book_id LIMIT 1") }
      end

      def recover_downloads
        @lock.synchronize do
          @db.execute("UPDATE downloads SET state = 'paused' WHERE state = 'pausing'")
          @db.execute("UPDATE downloads SET state = CASE WHEN (SELECT downloaded_at FROM books WHERE id = book_id) IS NULL THEN 'queued' ELSE 'done' END WHERE state = 'downloading'")
        end
      end

      def cancelling_downloads(except: nil)
        @reader.call do |db|
          db.execute("SELECT book_id FROM downloads WHERE state = 'cancelling' AND book_id != ? ORDER BY book_id LIMIT 100", [except || -1])
            .map { |row| row.fetch("book_id") }
        end
      end

      def save_download(id, details)
        @lock.synchronize do
          @db.execute(<<~SQL, [id, details.fetch(:status).to_s, JSON.generate(details.reject { |key, _| %i[book status].include?(key) })])
            INSERT INTO downloads(book_id, state, details) VALUES (?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET state=excluded.state, details=excluded.details
          SQL
        end
      end

      def forget_download(id)
        @lock.synchronize { @db.execute("DELETE FROM downloads WHERE book_id = ?", [id]) }
      end

      def page_count(file_id)
        @reader.call { |db| db.get_first_value("SELECT count(*) FROM pages WHERE file_id = ?", [file_id]) }
      end

      private

      def download_selection(filter, ungrouped: false, category_id: nil)
        raise ArgumentError, "Unknown download filter" unless %i[done active all].include?(filter.to_sym)

        if category_id
          condition = { all: "", done: "AND b.downloaded_at IS NOT NULL", active: "AND b.downloaded_at IS NULL" }.fetch(filter.to_sym)
          return <<~SQL
            SELECT m.book_id, b.downloaded_at IS NOT NULL AS completed, coalesce(d.queued_at, '') AS queued_at
            FROM category_download_books m JOIN books b ON b.id = m.book_id LEFT JOIN downloads d ON d.book_id = m.book_id
            WHERE m.category_id = #{Integer(category_id)} #{condition}
          SQL
        end
        queries = []
        queries << "SELECT id AS book_id, 1 AS completed, '' AS queued_at FROM books WHERE downloaded_at IS NOT NULL" unless filter.to_sym == :active
        queries << "SELECT d.book_id, 0 AS completed, d.queued_at FROM downloads d JOIN books b ON b.id = d.book_id WHERE d.state != 'done' AND b.downloaded_at IS NULL" unless filter.to_sym == :done
        selection = queries.join(" UNION ALL ")
        ungrouped ? "SELECT * FROM (#{selection}) WHERE book_id NOT IN (SELECT book_id FROM category_download_books)" : selection
      end

      def download_details(row)
        details = JSON.parse(row["details"] || "{}", symbolize_names: true)
        if row["downloaded_at"]
          details.merge!(status: :done, fraction: 1, message: "متاح دون اتصال", bytes: row["download_bytes"])
        else
          details[:status] = (row["state"] || "cancelled").to_sym
          details = { fraction: 0, message: "تم إلغاء التنزيل", **details }
        end
        details.merge(book: JSON.parse(row.fetch("data")))
      end
    end
  end
end
