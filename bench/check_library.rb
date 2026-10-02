# frozen_string_literal: true

require_relative "../lib/aljam3"
require "tmpdir"
require "timeout"

path = ARGV.fetch(0, ".cache/benchmark/full/library.sqlite3")
temporary = File.join(File.dirname(File.expand_path(path)), "tmp")
FileUtils.mkdir_p(temporary)
ENV["SQLITE_TMPDIR"] = temporary
manifest = JSON.parse(File.read(".cache/benchmark/source/manifest.json"))
books = JSON.parse(File.read(".cache/benchmark/source/catalog.json"))
texts = manifest.fetch("samples").flat_map { |sample| File.read(sample.fetch("path")).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
extension = ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION")
store = Aljam3::Store.new(path)
db = store.instance_variable_get(:@db)
target = store.preference("benchmark:pages")
raise "Not a marked benchmark fixture" unless target
raise "Fixture is incomplete" unless db.get_first_value("SELECT count(*) FROM pages") == target
raise "Books are incomplete" unless store.downloaded_ids == books.map { |book| book.fetch("id") }.to_set
raise "Page IDs are incomplete" unless db.get_first_value("SELECT min(id) FROM pages") == 1 && db.get_first_value("SELECT max(id) FROM pages") == target
report = { pages: target, books: books.size, sampled_pages: [], queries: {}, recorded_at: Time.now.utc.iso8601 }
$stdout.sync = true

begin
  raise "SQLite quick_check failed" unless db.execute("PRAGMA quick_check").map(&:values).flatten == ["ok"]
  report[:quick_check] = "ok"
  puts JSON.generate(check: "quick_check", result: "ok")

  random = Random.new(42)
  [1, target, *Array.new(30) { random.rand(1..target) }].each do |id|
    row = store.find_page(id)
    raise "Wrong content for page #{id}" unless row.fetch("content") == "#{texts[(id * 7919) % texts.size]}\n#{id}"
    report[:sampled_pages] << id
  end

  SQLite3::Database.new(":memory:", extensions: [extension]) do |reference|
    reference.execute("CREATE VIRTUAL TABLE samples USING fts5(content, tokenize='sqlite_tokenizer_ar disable_stopwords')")
    reference.transaction do
      texts.each_with_index { |text, index| reference.execute("INSERT INTO samples(rowid, content) VALUES (?, ?)", [index + 1, text]) }
    end
    ["الله", "في", "العلم العمل", "الزمخشري", "كلمةغيرموجودةللاختبار"].each do |query|
      match = Aljam3::Text.match_query(query)
      matching_samples = reference.execute("SELECT rowid FROM samples WHERE samples MATCH ?", [match]).map { |row| row.first - 1 }.to_set
      prefix_count = ->(last) do
        cycles, remainder = last.divmod(texts.size)
        cycles * matching_samples.size + (1..remainder).count { |id| matching_samples.include?((id * 7919) % texts.size) }
      end
      expected = prefix_count.call(target)
      actual = db.get_first_value("SELECT count(*) FROM pages_fts WHERE pages_fts MATCH ?", [match])
      raise "Missing or extra matches for #{query}: #{actual} vs #{expected}" unless actual == expected

      scoped = [books.first, books[books.size / 2], books.last].map do |book|
        id = book.fetch("id")
        bounds = db.get_first_row("SELECT first_page_id, last_page_id FROM files WHERE book_id = ?", [id])
        expected_count = prefix_count.call(bounds.fetch("last_page_id")) - prefix_count.call(bounds.fetch("first_page_id") - 1)
        result = store.search(query, book_id: id)
        raise "Wrong book count" unless result.dig("pagination", "count_is_exact") && result.dig("pagination", "count") == expected_count
        raise "Wrong book filter" unless result.fetch("pages").all? { |hit| hit.dig("book", "id") == id }
        { book: id, count: expected_count }
      end
      report[:queries][query] = { expected:, actual:, scoped: }
      puts JSON.generate(query:, expected:, actual:)
    end
  end

  query = "الله"
  # The rank cursor is an independent, exhaustive reference for the app's
  # bounded BM25 plan. Compare across the five-page cache boundary as well.
  expected = db.execute("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ? ORDER BY rank LIMIT 72", [Aljam3::Text.match_query(query)]).map { |row| row.fetch("rowid") }
  actual = (1..6).flat_map { |page| store.search(query, page:).fetch("pages").map { |hit| hit.fetch("id") } }
  raise "Ranked pagination differs" unless actual == expected
  report[:ranked_pages_verified] = 6

  expected = db.execute("SELECT rowid FROM pages_fts WHERE pages_fts MATCH ? ORDER BY rowid LIMIT 72", [Aljam3::Text.match_query(query)]).map { |row| row.fetch("rowid") }
  actual = (1..6).flat_map { |page| store.search(query, page:, order: "library").fetch("pages").map { |hit| hit.fetch("id") } }
  raise "Library-order pagination differs" unless actual == expected
  report[:library_pages_verified] = 6

  store.cancel_search
  searching = Thread.new do
    store.search("في")
  rescue Aljam3::Store::Worker::Cancelled
    :cancelled
  end
  sleep 0.1
  file_id = books[books.size / 2].fetch("id")
  reads = Array.new(20) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise "Page read failed" unless store.page(file_id, 1)
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    sleep 0.01
    elapsed
  end
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Timeout.timeout(5) { store.cancel_search; searching.join }
  raise "Search finished before cancellation could be checked" unless searching.value == :cancelled
  report[:cancellation_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
  report[:reading_during_search_max_ms] = reads.max.round(2)
  report[:passed] = true
  destination = File.join(File.dirname(path), "verification.json")
  File.write(destination, JSON.pretty_generate(report))
  puts JSON.generate(report)
ensure
  store.close
  searching&.join
end
