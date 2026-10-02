# frozen_string_literal: true

module Aljam3
  class Store
    module Downloads
      def downloads
        @lock.synchronize do
          @db.execute("SELECT d.*, b.data FROM downloads d JOIN books b ON b.id = d.book_id ORDER BY json_extract(d.details, '$.queued_at'), d.book_id").to_h do |row|
            details = JSON.parse(row.fetch("details"), symbolize_names: true)
            [row.fetch("book_id"), details.merge(status: row.fetch("state").to_sym, book: JSON.parse(row.fetch("data")))]
          end
        end
      end

      def save_download(id, details)
        @lock.synchronize do
          @db.execute(<<~SQL, [id, details.fetch(:status).to_s, JSON.generate(details.reject { |key, _| %i[book status].include?(key) })])
            INSERT INTO downloads VALUES (?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET state=excluded.state, details=excluded.details
          SQL
        end
      end

      def forget_download(id)
        @lock.synchronize { @db.execute("DELETE FROM downloads WHERE book_id = ?", [id]) }
      end

      def page_count(file_id)
        @lock.synchronize { @db.get_first_value("SELECT count(*) FROM pages WHERE file_id = ?", [file_id]) }
      end
    end
  end
end
