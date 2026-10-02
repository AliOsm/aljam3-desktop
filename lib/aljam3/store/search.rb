# frozen_string_literal: true

module Aljam3
  class Store
    class Search
      POOL_SIZE = 10_000
      COUNT_LIMIT = 1000
      JOIN = "FROM pages_fts JOIN pages p ON p.id = pages_fts.rowid JOIN files f ON f.id = p.file_id JOIN books b ON b.id = f.book_id"

      def initialize(db)
        @db = db
      end

      def call(query, page: 1, order: "relevance", pool_size: POOL_SIZE, category: nil, author: nil, library: nil, book_id: nil)
        raise ArgumentError, "Unknown search order" unless %w[library relevance].include?(order.to_s)

        match = Text.match_query(query)
        page, pool_size = [Integer(page), 1].max, [Integer(pool_size), 1].max
        scopes = { "b.category_id" => category, "b.author_id" => author, "b.library_id" => library, "b.id" => book_id }.compact
        base, terms = query_scope(match, scopes)
        if order.to_s == "relevance"
          key = [@db.get_first_value("PRAGMA data_version"), match, scopes, pool_size]
          prepare_pool(base, terms, match, pool_size, key) unless @pool_key == key
          offset = (page - 1) * PAGE_SIZE
          ids = @ranked_ids.slice(offset, PAGE_SIZE) || []
          rows = ranked_pages(match, ids)
          result(rows, page:, count: @ranked_ids.size, exact: !@pool_more, more: offset + PAGE_SIZE < @ranked_ids.size,
            order: "relevance", ranking: { "candidates" => @ranked_ids.size, "has_more" => @pool_more,
              "next_pool_size" => @pool_more ? pool_size + POOL_SIZE : nil })
        else
          library_pages(base, terms, match, page)
        end
      end

      private

      def query_scope(match, scopes)
        conditions = ["pages_fts MATCH ?", "b.downloaded_at IS NOT NULL", *scopes.keys.map { |column| "#{column} = ?" }]
        terms = [match, *scopes.values]
        unless scopes.empty?
          bounds = @db.get_first_row("SELECT min(f.first_page_id) AS first, max(f.last_page_id) AS last FROM files f JOIN books b ON b.id=f.book_id WHERE b.downloaded_at IS NOT NULL AND #{scopes.keys.map { |column| "#{column} = ?" }.join(' AND ')}", scopes.values)
          conditions.concat(["pages_fts.rowid >= ?", "pages_fts.rowid <= ?"])
          terms.concat([bounds["first"] || 0, bounds["last"] || -1])
        end
        ["#{JOIN} WHERE #{conditions.join(' AND ')}", terms]
      end

      def prepare_pool(base, terms, match, limit, key)
        extending = @pool_key && @pool_key.first(3) == key.first(3) && limit > @pool_key.last
        @pool_key = nil
        ids = match.empty? ? [] : @db.execute("SELECT p.id #{base} ORDER BY pages_fts.rowid LIMIT ?", [*terms, limit + 1]).map { |row| row.fetch("id") }
        @pool_more = ids.size > limit
        ids.pop if @pool_more
        unless extending
          # Dropping the temporary index avoids re-tokenizing its old text on DELETE.
          @db.execute("DROP TABLE IF EXISTS temp.search_pool")
          @db.execute("CREATE VIRTUAL TABLE temp.search_pool USING fts5(content, tokenize='sqlite_tokenizer_ar disable_stopwords')")
        end
        # Keep text inside SQLite. Both BM25 statistics and scoring are local to
        # this pool; scoring on the original index would still scan global terms.
        additions = extending ? ids - @candidate_ids : ids
        @db.execute("INSERT INTO search_pool(rowid, content) SELECT id, content FROM pages WHERE id IN (SELECT value FROM json_each(?))", [JSON.generate(additions)])
        @ranked_ids = ids.empty? ? [] : @db.execute("SELECT rowid FROM search_pool WHERE search_pool MATCH ? ORDER BY bm25(search_pool), rowid", [match]).map { |row| row.fetch("rowid") }
        @candidate_ids = ids
        @pool_key = key
      end

      def ranked_pages(match, ids)
        return [] if ids.empty?

        rows = @db.execute(<<~SQL, [match, JSON.generate(ids)]).to_h { |row| [row.fetch("id"), row] }
          SELECT p.id, p.file_id, p.number, p.content, b.data,
            snippet(search_pool, 0, '', '', '…', 42) AS excerpt
          FROM search_pool JOIN pages p ON p.id=search_pool.rowid
            JOIN files f ON f.id=p.file_id JOIN books b ON b.id=f.book_id
          WHERE search_pool MATCH ? AND search_pool.rowid IN (SELECT value FROM json_each(?))
        SQL
        ids.map { |id| rows.fetch(id) }
      end

      def library_pages(base, terms, match, page)
        offset = (page - 1) * PAGE_SIZE
        count = match.empty? ? 0 : @db.get_first_value("SELECT count(*) FROM (SELECT 1 #{base} ORDER BY pages_fts.rowid LIMIT ?)", [*terms, COUNT_LIMIT + 1])
        exact = count <= COUNT_LIMIT
        rows = count.zero? ? [] : @db.execute(<<~SQL, [*terms, PAGE_SIZE + 1, offset])
          SELECT p.id, p.file_id, p.number, p.content, b.data,
            snippet(pages_fts, 0, '', '', '…', 42) AS excerpt
          #{base} ORDER BY pages_fts.rowid LIMIT ? OFFSET ?
        SQL
        more = rows.size > PAGE_SIZE
        rows = rows.first(PAGE_SIZE) if more
        count, exact = offset + rows.size, true if rows.any? && !more
        result(rows, page:, count: exact ? count : [COUNT_LIMIT, offset + rows.size].max, exact:, more:, order: "library")
      end

      def result(rows, page:, count:, exact:, more:, order:, ranking: nil)
        { "pages" => rows.map { |row| row.merge("book" => JSON.parse(row.delete("data"))) },
          "pagination" => { "count" => count, "count_is_exact" => exact, "current_page" => page,
            "total_pages" => exact ? [count.fdiv(PAGE_SIZE).ceil, 1].max : nil, "next_page" => more ? page + 1 : nil },
          "order" => order, "ranking" => ranking }
      end
    end
  end
end
