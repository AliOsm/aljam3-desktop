# frozen_string_literal: true

# Read-only measurements of the marked, repeated-OCR fixture. PDFs and the
# native renderer are deliberately excluded from both timing and memory data.
require "bundler/setup"
require "json"
require_relative "../lib/aljam3"

path, output = ARGV
abort "Usage: ruby bench/limited.rb FIXTURE.sqlite3 REPORT.json" unless path && output
temporary = File.join(File.dirname(File.expand_path(path)), "tmp")
FileUtils.mkdir_p(temporary)
ENV["SQLITE_TMPDIR"] = temporary
store = Aljam3::Store.new(path)
pages = store.preference("benchmark:pages")
abort "Not a marked benchmark fixture" unless pages
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
report = { pages:, bytes: File.size(path), ruby: RUBY_VERSION, sqlite: SQLite3::SQLITE_VERSION,
  recorded_at: Time.now.utc.iso8601, fixture: "7,031 sampled OCR pages repeated with numeric suffixes; PDFs excluded",
  temporary_directory: temporary,
  cache: "Uncontrolled OS cache; pool rebuilt before each initial query; worker already running",
  ranking: "BM25 within first eligible matching pages in rowid order, not global relevance",
  measurements: {}, peak_rss_kib: 0, heartbeat_max_ms: 0 }
monitoring = true
monitor = Thread.new do
  previous = clock.call
  while monitoring
    now = clock.call
    report[:heartbeat_max_ms] = [report[:heartbeat_max_ms], (now - previous) * 1000].max
    previous = now
    if File.file?("/proc/self/status")
      children = File.read("/proc/self/task/#{Process.pid}/children").split
      rss = [Process.pid, *children].sum do |pid|
        File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
      rescue Errno::ENOENT
        0
      end
      report[:peak_rss_kib] = [report[:peak_rss_kib], rss].max
    end
    sleep 0.02
  end
end
measure = ->(label, before: nil, &work) do
  timings = Array.new(3) do
    before&.call
    started = clock.call
    work.call
    ((clock.call - started) * 1000).round(2)
  end
  report[:measurements][label] = { median_ms: timings.sort[1], trials_ms: timings }
  puts JSON.generate(label:, **report[:measurements][label])
  $stdout.flush
end
reset = -> { store.search("benchmarkcachemissunmatchedword") }
queries = { common: ["الله", {}], prefix: ["في", {}], three_words: ["العلم العمل الناس", {}],
  rare: ["الزمخشري", {}], author: ["الله", { author: 1 }], book: ["الله", { book_id: 31_767 }],
  no_match: ["كلمةغيرموجودةللاختبار", {}] }
begin
  [2_000, 5_000, 10_000].each do |pool_size|
    queries.each do |label, (query, scopes)|
      measure.call("#{label}_#{pool_size}", before: reset) do
        result = store.search(query, pool_size:, **scopes)
        raise "Pool exceeds cap" if result.dig("ranking", "candidates") > pool_size
        raise "Unstable tie or duplicate" unless result.fetch("pages").uniq { |hit| hit.fetch("id") } == result.fetch("pages")
      end
    end
  end
  measure.call("expand_10k_to_20k", before: -> { reset.call; store.search("الله") }) do
    result = store.search("الله", pool_size: 20_000)
    raise "Expansion failed" unless result.dig("ranking", "candidates") == 20_000
  end
  store.search("الله")
  first = store.search("الله").fetch("pages").map { |hit| hit.fetch("id") }
  measure.call("cached_page_2") { store.search("الله", page: 2) }
  measure.call("cached_page_800") { store.search("الله", page: 800) }
  raise "Cached ordering changed" unless store.search("الله").fetch("pages").map { |hit| hit.fetch("id") } == first
  measure.call("library_order") { store.search("الله", order: "library") }
  measure.call("catalog") { store.catalog(downloaded: true) }
  measure.call("page_read") { store.page(31_767, 1) }
  # A page remains readable while the independent search worker is busy.
  reset.call
  search = Thread.new do
    store.search("في", pool_size: 100_000)
  rescue Aljam3::Store::Worker::Cancelled
    :cancelled
  end
  sleep 0.1
  measure.call("page_read_during_search") { store.page(31_767, 1) }
  started = clock.call
  store.cancel_search
  report[:cancel_ms] = ((clock.call - started) * 1000).round(2)
  raise "Search did not cancel" unless search.value == :cancelled
  report[:verified] = true
ensure
  monitoring = false
  monitor.join
  report[:heartbeat_max_ms] = report[:heartbeat_max_ms].round(2)
  File.write(output, JSON.pretty_generate(report))
  store.close
end
