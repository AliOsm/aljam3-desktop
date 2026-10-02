# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class LargeLibraryTest < StoreTestCase
  def test_worker_uses_the_application_gems_when_a_launcher_resets_the_environment
    install_book
    env = { "GEM_HOME" => @directory, "GEM_PATH" => @directory, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil }
    input = JSON.generate(method: "search", arguments: ["العلم"], options: {}) + "\n"
    output, errors, status = Open3.capture3(env, RbConfig.ruby,
      File.join(Aljam3::ROOT, "lib/aljam3/store/worker_main.rb"), File.join(@directory, "library.sqlite3"), Gem.dir,
      Gem.loaded_specs.fetch("sqlite3").version.to_s, *Gem.path,
      stdin_data: input)
    assert status.success?, errors
    assert_equal 2, JSON.parse(output).fetch("result").fetch("pages").length
  end

  def test_version_three_upgrade_preserves_original_pages_and_download_sizes
    path = File.join(@directory, "version-three.sqlite3")
    extension = ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION") { File.join(Aljam3::ROOT, "vendor/tokenizer/sqlite_tokenizer_ar.#{Gem.win_platform? ? 'dll' : 'so'}") }
    SQLite3::Database.new(path, extensions: [extension]) do |db|
      db.execute_batch(File.read(File.join(__dir__, "fixtures/schema_v3.sql")))
      db.execute("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?)", [1, "آداب العلم", "اداب العلم", 2, JSON.generate(book), "2026-09-30"])
      db.execute("INSERT INTO files VALUES (?, ?, ?, ?)", [10, 1, 0, JSON.generate(book.fetch("files").first)])
      pages.each { |page| db.execute("INSERT INTO pages VALUES (?, ?, ?, ?)", [page.fetch("id"), 10, page.fetch("number"), page.fetch("content")]) }
      db.execute("INSERT INTO downloads VALUES (?, ?, ?)", [1, "done", JSON.generate({ bytes: 500, queued_at: "2026-09-30" })])
    end
    upgraded = Aljam3::Store.new(path)
    assert_equal [100, 101], upgraded.search("العلم").fetch("pages").map { |hit| hit.fetch("id") }.sort
    assert_equal pages.first.fetch("content"), upgraded.page(10, 1).fetch("content")
    assert_equal 500, upgraded.download_bytes
    assert_equal :done, upgraded.download(1).fetch(:status)
    assert_equal [4], upgraded.authors(downloaded: true).fetch("authors").map { |author| author.fetch("id") }
  ensure
    upgraded&.close
  end

  def test_relevance_search_ranks_every_match_and_paginates_without_gaps
    @store.prepare_download(book)
    rows = Array.new(1_100) { |index| { "id" => index + 1, "number" => index + 1, "content" => "العلم #{'تمهيد ' * 30}" } }
    rows << { "id" => 2_000, "number" => 1_101, "content" => "العلم" }
    @store.add_pages(10, rows)
    @store.complete_download(1)
    result = @store.search("العلم")
    assert_equal "relevance", result.fetch("order")
    assert_equal 2_000, result.fetch("pages").first.fetch("id"), "Best result is beyond the bounded count probe"
    refute result.dig("pagination", "count_is_exact")
    assert_equal 1_000, result.dig("pagination", "count")
    assert_nil result.dig("pagination", "total_pages")

    expected = @store.instance_variable_get(:@db).execute(<<~SQL, [Aljam3::Text.match_query("العلم")]).map { |row| row.fetch("rowid") }
      SELECT rowid FROM pages_fts WHERE pages_fts MATCH ? ORDER BY bm25(pages_fts), rowid
    SQL
    ids = []
    loop do
      ids.concat(result.fetch("pages").map { |hit| hit.fetch("id") })
      following = result.dig("pagination", "next_page")
      break unless following

      result = @store.search("العلم", page: following)
    end
    assert_equal expected, ids
    assert_equal 1_101, result.dig("pagination", "count")
    assert result.dig("pagination", "count_is_exact")
    assert_equal 1, @store.search("العلم", order: "library").fetch("pages").first.fetch("id")
    assert_equal 0, @store.search("!", page: 5).dig("pagination", "count")
  end

  def test_filters_remain_correct_with_interleaved_page_ids_and_cached_results
    [1, 2].each do |id|
      @store.prepare_download(book(id, category: id).merge("author" => { "id" => id, "name" => "مؤلف #{id}" }))
      @store.add_pages(id * 10, Array.new(20) { |i| { "id" => i * 2 + id, "number" => i + 1, "content" => "علم كتاب" } })
      @store.complete_download(id)
    end
    result = @store.search("علم", author: 1, category: 1, book_id: 1)
    assert_equal [1], result.fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    assert_equal 20, result.dig("pagination", "count")
    assert_empty @store.search("علم", author: 2, book_id: 1).fetch("pages")
    @store.search("علم")
    @store.discard_download(1)
    assert_equal [2], @store.search("علم").fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
  end

  def test_dense_search_preserves_full_index_excerpts_across_queries
    @store.prepare_download(book)
    rows = Array.new(1_105) do |index|
      content = "#{'مقدمة ' * (index % 30)}العِلْمُ والعمل أساس الفهم. #{'كلام ' * 45}العلم نور والعمل ثمرة العلم.\n#{index}"
      { "id" => index + 1, "number" => index + 1, "content" => content }
    end
    @store.add_pages(10, rows)
    @store.complete_download(1)
    db = @store.instance_variable_get(:@db)
    ["العلم", "العلم العمل"].each do |query|
      expected = db.execute(<<~SQL, [Aljam3::Text.match_query(query)])
        SELECT rowid, snippet(pages_fts, 0, '', '', '…', 42) AS excerpt
        FROM pages_fts WHERE pages_fts MATCH ? ORDER BY rank LIMIT 24
      SQL
      actual = (1..2).flat_map { |page| @store.search(query, page:).fetch("pages") }
      assert_equal expected.map { |row| row.fetch("rowid") }, actual.map { |row| row.fetch("id") }
      assert_equal expected.map { |row| row.fetch("excerpt") }, actual.map { |row| row.fetch("excerpt") }
    end
  end

  def test_partial_books_never_enter_ranked_results_and_completion_invalidates_the_cache
    @store.prepare_download(book)
    @store.add_pages(10, Array.new(1_101) do |index|
      { "id" => index + 1, "number" => index + 1, "content" => "العلم #{'تمهيد ' * 30}" }
    end)
    @store.complete_download(1)
    assert_equal [1], @store.search("العلم").fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    @store.prepare_download(book(2))
    @store.add_pages(20, [{ "id" => 2_000, "number" => 1, "content" => "العلم" }])
    assert_equal [1], @store.search("العلم").fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    @store.complete_download(2)
    assert_equal 2_000, @store.search("العلم").fetch("pages").first.fetch("id")
    @store.discard_download(2)
    assert_equal [1], @store.search("العلم").fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
  end

  def test_downloads_are_paginated_and_legacy_completed_books_are_included
    @store.cache_books((1..40).map { |id| book(id) })
    (1..39).each { |id| @store.complete_download(id, bytes: 100) }
    @store.save_download(40, status: :queued, fraction: 0, queued_at: "2026-01-01", message: "queued")
    assert_equal 40, @store.downloads.keys.first
    assert_equal 12, @store.downloads.size
    assert_equal [40], @store.downloads(filter: :active).keys
    assert_equal 39, @store.download_count(filter: :done)
    assert_equal 3_900, @store.download_bytes
    assert_equal (1..39).to_a, (1..4).flat_map { |page| @store.downloads(filter: :done, page:).keys }
    @store.discard_download(1)
    assert_equal 3_800, @store.download_bytes
    assert_equal 40, @store.next_download
  end

  def test_failed_page_batch_rolls_back_before_retrying
    @store.prepare_download(book)
    rows = Array.new(600) { |index| { "id" => index + 1, "number" => index + 1, "content" => "العلم" } }
    assert_raises(RuntimeError) { @store.add_pages(10, rows + [{ "id" => 601, "number" => 601 }]) }
    assert_equal 0, @store.page_count(10)
    @store.add_pages(10, rows)
    @store.complete_download(1)
    assert_equal 600, @store.search("العلم").dig("pagination", "count")
  end

  def test_blocked_indexer_does_not_block_reads_and_can_be_cancelled_and_restarted
    @store.prepare_download(book)
    db = @store.instance_variable_get(:@db)
    indexer = @store.instance_variable_get(:@indexer)
    db.execute("BEGIN IMMEDIATE")
    indexing = Thread.new do
      @store.add_pages(10, pages)
    rescue Aljam3::Store::Worker::Cancelled => error
      error
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reads = 0
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 0.3
      assert_equal 1, @store.book(1).fetch("id")
      reads += 1
      sleep 0.01
    end
    assert_operator reads, :>=, 5
    assert indexing.alive?, "Writer should be waiting for the held transaction"
    Timeout.timeout(2) { indexer.cancel; indexing.join }
    assert_instance_of Aljam3::Store::Worker::Cancelled, indexing.value
    db.execute("ROLLBACK")
    assert_equal 0, @store.page_count(10)
    @store.add_pages(10, pages)
    assert_equal 2, @store.page_count(10)
  ensure
    db.execute("ROLLBACK") if db&.transaction_active?
    indexing&.kill&.join
  end
end
