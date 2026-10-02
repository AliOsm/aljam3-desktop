# frozen_string_literal: true

require "bundler/setup"
require "json"
require "optparse"
require "fileutils"
require "shellwords"
require_relative "../lib/aljam3"
require_relative "bulk_pages"

options = { pages: 1_000_000, path: ".cache/benchmark/library.sqlite3", label: "baseline", prepare: false, runs: 3 }
OptionParser.new do |parser|
  parser.on("--pages N", Integer) { |value| options[:pages] = value }
  parser.on("--path PATH") { |value| options[:path] = value }
  parser.on("--label NAME") { |value| options[:label] = value }
  parser.on("--prepare") { options[:prepare] = true }
  parser.on("--runs N", Integer) { |value| options[:runs] = value }
  parser.on("--token-cache PATH") { |value| options[:token_cache] = File.expand_path(value) }
end.parse!
abort "Page and run counts must be positive" unless options[:pages].positive? && options[:runs].positive?
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
source = File.expand_path("../.cache/benchmark/source", __dir__)
manifest = JSON.parse(File.read(File.join(source, "manifest.json")))
books = JSON.parse(File.read(File.join(source, "catalog.json")))
report = { label: options[:label], requested_pages: options[:pages], source_books: books.size, ruby: RUBY_VERSION,
  sqlite: SQLite3::SQLITE_VERSION, samples: manifest, measurements: {}, token_cache: options[:token_cache],
  fixture: "Sampled real OCR repeated deterministically, with a unique numeric suffix on every page", recorded_at: Time.now.utc.iso8601 }
if options[:prepare] && options[:token_cache]
  ENV["ALJAM3_BENCH_TOKENIZER"] = ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION")
  ENV["SQLITE_TOKENIZER_AR_EXTENSION"] = options[:token_cache]
end
store = Aljam3::Store.new(options[:path], background: !options[:prepare])
db = store.instance_variable_get(:@db)
report_path = "#{File.dirname(options[:path])}/#{options[:label]}.json"
save = -> { File.write(report_path, JSON.pretty_generate(report)) }

if options[:prepare]
  report[:preexisting_pages] = db.get_first_value("SELECT count(*) FROM pages")
  report[:preexisting_completed_books] = db.get_first_value("SELECT count(*) FROM books WHERE downloaded_at IS NOT NULL")
  previous_target = store.preference("benchmark:pages")
  abort "Use a fresh benchmark path when changing the target page count" if previous_target && previous_target != options[:pages]
  abort "Refusing to overwrite an unmarked database" if !previous_target && db.get_first_value("SELECT count(*) FROM books").positive?
  store.save_preference("benchmark:pages", options[:pages])
  texts = manifest.fetch("samples").flat_map { |sample| File.read(sample.fetch("path")).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
  report[:sample_pages] = texts.size
  report[:sample_average_bytes] = texts.sum(&:bytesize).fdiv(texts.size)
  if options[:token_cache]
    bulk = BulkPages.new(db, texts)
    # Disposable fixture only. Normal app indexing is measured by indexing.rb.
    db.execute_batch("PRAGMA synchronous = NORMAL; PRAGMA cache_size = -65536;")
    report[:fixture_acceleration] = { bulk_sql: true, synchronous: "NORMAL", writer_cache_mib: 64, batch: "one book" }
  end
  started = clock.call
  count = 0
  books.each_with_index do |book, index|
    pages = options[:pages] / books.size + (index < options[:pages] % books.size ? 1 : 0)
    file_id = book.fetch("id")
    file = { "id" => file_id, "name" => "المجلد الأول", "pages_count" => pages, "urls" => {} }
    book = book.merge("files" => [file], "pages_count" => pages)
    next if store.downloaded?(book.fetch("id")) && (count += pages)

    store.prepare_download(book)
    pages.times.each_slice(bulk ? [pages, 500].max : 500) do |batch|
      if bulk
        bulk.add(file_id, count, batch)
        next
      end
      rows = batch.map do |number|
        id = count + number + 1
        { "id" => id, "number" => number + 1, "content" => "#{texts[(id * 7919) % texts.size]}\n#{id}" }
      end
      store.add_pages(file_id, rows)
    end
    store.complete_download(book.fetch("id"), bytes: pages * 30_000)
    store.save_download(book.fetch("id"), { status: :done, fraction: 1, bytes: pages * 30_000, message: "اكتمل", queued_at: "2026-10-01T00:00:00Z" })
    count += pages
    if (index + 1) % 1000 == 0
      puts JSON.generate(prepared_books: index + 1, pages: count, seconds: (clock.call - started).round(2))
      $stdout.flush
      report[:prepared_pages] = count
      report[:elapsed_prepare_seconds] = clock.call - started
      save.call
      # Keep the host usable; benchmark data is disposable and resumable.
      free = `df -Pk #{File.dirname(File.expand_path(options[:path])).shellescape}`.lines.last.split[3].to_i * 1024
      abort "Stopped with fewer than 8 GiB free; completed books can be resumed." if free < 8 * 1024**3
    end
  end
  report[:prepare_seconds] = clock.call - started
  db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
  store.close
  ENV["SQLITE_TOKENIZER_AR_EXTENSION"] = ENV.delete("ALJAM3_BENCH_TOKENIZER") if options[:token_cache]
  store = Aljam3::Store.new(options[:path])
  db = store.instance_variable_get(:@db)
end

report[:actual_pages] = db.get_first_value("SELECT count(*) FROM pages")
report[:actual_books] = db.get_first_value("SELECT count(*) FROM books")
report[:completed_books] = db.get_first_value("SELECT count(*) FROM books WHERE downloaded_at IS NOT NULL")
report[:sqlite_page_size] = db.get_first_value("PRAGMA page_size")
report[:sqlite_freelist_pages] = db.get_first_value("PRAGMA freelist_count")
report[:database_bytes] = File.size(options[:path])
monitoring = true
report[:peak_total_rss_kib], report[:heartbeat_max_ms] = 0, 0
monitor = Thread.new do
  last = clock.call
  while monitoring
    now = clock.call
    report[:heartbeat_max_ms] = [report[:heartbeat_max_ms], ((now - last) * 1000).round(2)].max
    last = now
    if File.file?("/proc/self/status")
      children = File.read("/proc/self/task/#{Process.pid}/children").split
      rss = [Process.pid, *children].sum do |pid|
        File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
      rescue Errno::ENOENT
        0
      end
      report[:peak_total_rss_kib] = [report[:peak_total_rss_kib], rss].max
    end
    sleep 0.02
  end
end
measure = ->(name, before: nil, &work) do
  times = Array.new(options[:runs]) do
    before&.call
    started = clock.call
    result = work.call
    elapsed = (clock.call - started) * 1000
    puts JSON.generate(operation: name, ms: elapsed.round(2), results: result.respond_to?(:size) ? result.size : nil)
    $stdout.flush
    elapsed
  end
  report[:measurements][name] = { first_ms: times.first.round(2), median_ms: times.sort[times.size / 2].round(2), max_ms: times.max.round(2) }
  save.call
end
measure.call("catalog") { store.catalog(downloaded: true) }
measure.call("catalog_filtered") { store.catalog(downloaded: true, author: 1) }
measure.call("catalog_deep") { store.catalog(downloaded: true, page: 5000) }
measure.call("authors") { store.authors(downloaded: true) }
measure.call("downloads") { store.downloads }
measure.call("downloads_size") { store.download_bytes }
measure.call("downloads_count") { store.download_count }
uncached = -> { store.search("benchmarkcachemissunmatchedword") }
measure.call("common_word", before: uncached) { store.search("الله") }
measure.call("cached_next_page") { store.search("الله", page: 2) }
measure.call("common_prefix", before: uncached) { store.search("في") }
measure.call("multiple_words", before: uncached) { store.search("العلم العمل") }
measure.call("rare_word", before: uncached) { store.search("الزمخشري") }
measure.call("no_match", before: uncached) { store.search("كلمةغيرموجودةللاختبار") }
measure.call("filtered_common", before: uncached) { store.search("الله", author: 1) }
measure.call("book_search", before: uncached) { store.search("الله", book_id: books.size / 2) }
measure.call("search_page_100", before: uncached) { store.search("الله", page: 100) }
measure.call("read_page") { store.page(books.size / 2, 1) }
report[:peak_rss_kib] = File.read("/proc/self/status")[/^VmHWM:\s+(\d+)/, 1].to_i if File.file?("/proc/self/status")
monitoring = false
monitor.join
report[:indexed_matches] = %w[الله في العلم\ العمل الزمخشري].to_h do |query|
  [query, db.get_first_value("SELECT count(*) FROM pages_fts WHERE pages_fts MATCH ?", [Aljam3::Text.match_query(query)])]
end
save.call
store.close
