# frozen_string_literal: true

module Aljam3
  class Store
    class Search
      COUNT_LIMIT = 1000
      CACHE_PAGES = 5
      JOIN = "FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid JOIN files f ON f.id = p.file_id JOIN books b ON b.id = f.book_id"

      def initialize(db)
        @db = db
      end

      def call(query, page: 1, order: "relevance", category: nil, author: nil, library: nil, book_id: nil)
        match = Text.match_query(query)
        page = [Integer(page), 1].max
        raise ArgumentError, "Unknown search order" unless %w[library relevance].include?(order.to_s)

        scopes = { "b.category_id" => category, "b.author_id" => author, "b.library_id" => library, "b.id" => book_id }.compact
        first_page = ((page - 1) / CACHE_PAGES) * CACHE_PAGES + 1
        version = @db.get_first_value("PRAGMA data_version")
        @index_summary = nil if @data_version != version
        @data_version = version
        key = [version, match, order.to_s, scopes, first_page]
        if @cache_key != key
          @cache = fetch(match, scopes, order.to_s, first_page)
          @cache_key = key
        end
        rows = @cache.fetch(:rows)
        offset = (page - first_page) * PAGE_SIZE
        more = rows.size > offset + PAGE_SIZE
        count, exact = @cache.values_at(:count, :exact)
        count = [count, (first_page - 1) * PAGE_SIZE + rows.size - 1].max if !exact && rows.any?
        { "pages" => rows.slice(offset, PAGE_SIZE) || [], "pagination" => { "count" => count, "count_is_exact" => exact,
          "current_page" => page, "total_pages" => exact ? [(count.fdiv(PAGE_SIZE)).ceil, 1].max : nil,
          "next_page" => more ? page + 1 : nil }, "order" => order.to_s }
      end

      private

      def fetch(match, scopes, order, first_page)
        conditions = ["pages_fts MATCH ?", "b.downloaded_at IS NOT NULL", *scopes.keys.map { |column| "#{column} = ?" }]
        terms = [match, *scopes.values]
        unless scopes.empty?
          bounds = @db.get_first_row("SELECT min(f.first_page_id) AS first, max(f.last_page_id) AS last FROM files f JOIN books b ON b.id=f.book_id WHERE b.downloaded_at IS NOT NULL AND #{scopes.keys.map { |column| "#{column} = ?" }.join(' AND ')}", scopes.values)
          conditions.concat(["pages_fts.rowid >= ?", "pages_fts.rowid <= ?"])
          terms.concat([bounds["first"] || 0, bounds["last"] || -1])
        end
        base = "#{JOIN} WHERE #{conditions.join(' AND ')}"
        offset = (first_page - 1) * PAGE_SIZE
        ids = match.empty? ? [] : @db.execute("SELECT p.id #{base} ORDER BY pages_fts.rowid LIMIT ?", [*terms, COUNT_LIMIT + 1]).map { |row| row.fetch("id") }
        exact = ids.length <= COUNT_LIMIT
        count = [ids.length, COUNT_LIMIT].min
        columns = "p.id, p.file_id, p.number, p.content, snippet(pages_fts, 0, '', '', '…', 42) AS excerpt, b.data"
        rows = if ids.empty?
          []
        elsif order == "relevance" && scopes.empty? && dense_complete_index?(ids)
          ranked_pages(match, offset)
        elsif order == "relevance"
          @db.execute("SELECT #{columns} #{base} ORDER BY rank LIMIT ? OFFSET ?", [*terms, CACHE_PAGES * PAGE_SIZE + 1, offset])
        else
          @db.execute("SELECT #{columns} #{base} ORDER BY pages_fts.rowid LIMIT ? OFFSET ?", [*terms, CACHE_PAGES * PAGE_SIZE + 1, offset])
        end
        if rows.any? && rows.length < CACHE_PAGES * PAGE_SIZE + 1
          count, exact = offset + rows.length, true
        end
        hits = rows.map { |row| row.merge("book" => JSON.parse(row.delete("data"))) }
        { rows: hits, count:, exact: }
      end

      def dense_complete_index?(ids)
        return false if ids.size <= COUNT_LIMIT

        @index_summary ||= @db.get_first_row(<<~SQL)
          SELECT min(f.first_page_id) AS first, max(f.last_page_id) AS last,
            sum(json_extract(f.data, '$.pages_count')) AS pages,
            max(b.downloaded_at IS NULL) AS incomplete
          FROM files f JOIN books b ON b.id = f.book_id WHERE f.first_page_id IS NOT NULL
        SQL
        return false if @index_summary["incomplete"] == 1 || @index_summary["pages"].to_i.zero?

        # Estimate density from the count probe, adjusted for gaps in API IDs.
        # Sparse matches use the FTS sort to avoid a second prefix scan. Both
        # plans rank every match; the estimate affects performance only.
        library_density = @index_summary["pages"].fdiv(@index_summary["last"] - @index_summary["first"] + 1)
        (ids.size - 1).fdiv(ids.last - ids.first) >= library_density / 8
      end

      def ranked_pages(match, offset)
        # Explicit BM25 lets SQLite keep only the best rows while scoring every
        # match. ORDER BY rank instead sorts all matches inside the FTS cursor.
        # Without incomplete books or filters, metadata joins can follow ranking.
        ids = @db.execute(<<~SQL, [match, CACHE_PAGES * PAGE_SIZE + 1, offset]).map { |row| row.fetch("id") }
          SELECT rowid AS id
          FROM pages_fts WHERE pages_fts MATCH ? ORDER BY bm25(pages_fts), rowid LIMIT ? OFFSET ?
        SQL
        return [] if ids.empty?

        # Unary + keeps this a single bounded FTS scan, avoiding a separate
        # initialization of the prefix query for each requested excerpt.
        rows = @db.execute(<<~SQL, [match, *ids.minmax, JSON.generate(ids)]).to_h { |row| [row.fetch("id"), row] }
          SELECT p.id, p.file_id, p.number, p.content, b.data, snippet(pages_fts, 0, '', '', '…', 42) AS excerpt
          #{JOIN} WHERE pages_fts MATCH ? AND pages_fts.rowid BETWEEN ? AND ?
          AND +pages_fts.rowid IN (SELECT value FROM json_each(?))
        SQL
        ids.map { |id| rows.fetch(id) }
      end
    end
  end
end
