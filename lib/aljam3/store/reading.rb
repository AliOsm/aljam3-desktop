# frozen_string_literal: true

module Aljam3
  class Store
    module Reading
      def save_reading(book_id, file_id:, number:)
        save_preference("reading:#{book_id}", { "file_id" => file_id, "number" => number })
        @lock.synchronize do
          @db.execute(<<~SQL, [book_id, file_id, number, Time.now.utc.iso8601(6)])
            INSERT INTO reading_history VALUES (?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET file_id=excluded.file_id, number=excluded.number, read_at=excluded.read_at
          SQL
        end
      end

      def recent_books(limit: 12)
        @lock.synchronize do
          @db.execute(<<~SQL, [limit]).map { |row| row.merge("book" => JSON.parse(row.delete("data"))) }
            SELECT h.*, b.data FROM reading_history h JOIN books b ON b.id = h.book_id
            ORDER BY h.read_at DESC, h.book_id DESC LIMIT ?
          SQL
        end
      end

      def bookmarks(book_id)
        @lock.synchronize { @db.execute("SELECT * FROM bookmarks WHERE book_id = ? ORDER BY created_at DESC", [book_id]) }
      end

      def toggle_bookmark(book_id, file_id:, number:, excerpt:)
        @lock.synchronize do
          @db.transaction(:immediate) do
            keys = [book_id, file_id, number]
            exists = @db.get_first_value("SELECT 1 FROM bookmarks WHERE book_id = ? AND file_id = ? AND number = ?", keys)
            if exists
              @db.execute("DELETE FROM bookmarks WHERE book_id = ? AND file_id = ? AND number = ?", keys)
            else
              @db.execute("INSERT INTO bookmarks VALUES (?, ?, ?, ?, ?)", [*keys, excerpt, Time.now.utc.iso8601(6)])
            end
            !exists
          end
        end
      end
    end
  end
end
