# frozen_string_literal: true

module Aljam3
  class Store
    module CategoryDownloads
      def category_download_preview(category_id, book_ids)
        @reader.call do |db|
          rows = db.execute(<<~SQL, [JSON.generate(book_ids), category_id])
            SELECT CASE
              WHEN b.downloaded_at IS NOT NULL THEN 'done'
              WHEN d.state IN ('queued', 'downloading', 'pausing', 'cancelling')
                OR m.category_id != ?2 THEN 'existing'
              ELSE 'new' END AS status, count(*) AS count
            FROM json_each(?1) j JOIN books b ON b.id = j.value
            LEFT JOIN downloads d ON d.book_id = b.id
            LEFT JOIN category_download_books m ON m.book_id = b.id
            GROUP BY status
          SQL
          { total: book_ids.length, done: 0, existing: 0, new: 0 }.merge(rows.to_h { |row| [row.fetch("status").to_sym, row.fetch("count")] })
        end
      end

      # Claim and queue a snapshot in one transaction. Already queued books retain
      # their original owner, so category controls never stop independent work.
      def queue_category_download(category, book_ids)
        @lock.synchronize do
          # Reserve the writer before reading: the background indexer can commit
          # between the SELECT and INSERT, making a deferred WAL snapshot stale.
          @db.transaction(:immediate) do
            ids = @db.execute(<<~SQL, [JSON.generate(book_ids), category.fetch("id")]).map { |row| row.fetch("id") }
              SELECT DISTINCT b.id FROM json_each(?1) j JOIN books b ON b.id = j.value
              LEFT JOIN downloads d ON d.book_id = b.id
              LEFT JOIN category_download_books m ON m.book_id = b.id
              WHERE b.downloaded_at IS NULL
                AND coalesce(d.state, '') NOT IN ('queued', 'downloading', 'pausing', 'cancelling')
                AND (m.category_id IS NULL OR m.category_id = ?2)
            SQL
            next 0 if ids.empty?

            stamp = Time.now.utc.iso8601(6)
            @db.execute(<<~SQL, [category.fetch("id"), Text.plain(category.fetch("name")), stamp])
              INSERT INTO category_downloads VALUES (?, ?, ?)
              ON CONFLICT(category_id) DO UPDATE SET name = excluded.name
            SQL
            @db.execute("INSERT OR IGNORE INTO category_download_books SELECT value, ? FROM json_each(?)", [category.fetch("id"), JSON.generate(ids)])
            details = JSON.generate(fraction: 0, queued_at: stamp, message: "في قائمة الانتظار")
            @db.execute(<<~SQL, [JSON.generate(ids), details])
              INSERT INTO downloads(book_id, state, details)
              SELECT value, 'queued', ?2 FROM json_each(?1) WHERE true
              ON CONFLICT(book_id) DO UPDATE SET state = 'queued',
                details = json_patch(downloads.details, '{"message":"في قائمة الانتظار","failure":null}')
            SQL
            ids.length
          end
        end
      end

      def category_downloads(filter: :all)
        @reader.call do |db|
          db.execute(<<~SQL).map do |row|
            SELECT g.category_id, g.name, g.created_at, count(*) AS total,
              sum(b.downloaded_at IS NOT NULL) AS done,
              sum(b.downloaded_at IS NULL AND d.book_id IS NULL) AS cancelled,
              #{%w[queued downloading pausing paused cancelling failed].map { |state| "sum(CASE WHEN b.downloaded_at IS NULL AND d.state = '#{state}' THEN 1 ELSE 0 END) AS #{state}" }.join(", ")}
            FROM category_downloads g JOIN category_download_books m USING(category_id)
            JOIN books b ON b.id = m.book_id LEFT JOIN downloads d ON d.book_id = b.id
            GROUP BY g.category_id ORDER BY g.created_at DESC, g.category_id
          SQL
            row.transform_keys(&:to_sym)
          end.select do |group|
            case filter.to_sym
            when :all then true
            when :done then group[:done].positive?
            when :active then group[:done] < group[:total]
            else raise ArgumentError, "Unknown download filter"
            end
          end
        end
      end

      def download_category_id(book_id)
        @reader.call { |db| db.get_first_value("SELECT category_id FROM category_download_books WHERE book_id = ?", [book_id]) }
      end

      def category_download_book_ids(category_id, states: nil)
        @reader.call do |db|
          condition = states ? "AND d.state IN (SELECT value FROM json_each(?2))" : ""
          db.execute(<<~SQL, states ? [category_id, JSON.generate(states)] : [category_id]).map { |row| row.fetch("book_id") }
            SELECT m.book_id FROM category_download_books m LEFT JOIN downloads d USING(book_id)
            WHERE m.category_id = ?1 #{condition} ORDER BY m.book_id
          SQL
        end
      end

      def pause_category_download(category_id)
        @lock.synchronize do
          @db.execute(<<~SQL, [category_id])
            UPDATE downloads SET state = CASE WHEN state = 'downloading' THEN 'pausing' ELSE 'paused' END,
              details = json_patch(details, '{"message":"متوقف مؤقتًا · يمكنك المتابعة لاحقًا"}')
            WHERE state IN ('queued', 'downloading') AND book_id IN (SELECT book_id FROM category_download_books WHERE category_id = ?)
          SQL
        end
      end

      def retry_category_cancellations(category_id)
        @lock.synchronize do
          @db.execute(<<~SQL, [category_id])
            UPDATE downloads SET state = 'cancelling',
              details = json_patch(details, '{"message":"جارٍ إلغاء التنزيل…"}')
            WHERE state = 'failed' AND json_extract(details, '$.failure') = 'cancel'
              AND book_id IN (SELECT book_id FROM category_download_books WHERE category_id = ?)
          SQL
        end
      end

      def cancel_category_download(category_id)
        @lock.synchronize do
          @db.execute(<<~SQL, [category_id])
            UPDATE downloads SET state = 'cancelling',
              details = json_patch(details, '{"message":"جارٍ إلغاء التنزيل…"}')
            WHERE book_id IN (SELECT book_id FROM category_download_books WHERE category_id = ?)
              AND book_id IN (SELECT id FROM books WHERE downloaded_at IS NULL)
          SQL
        end
      end
    end
  end
end
