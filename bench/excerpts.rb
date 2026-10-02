# frozen_string_literal: true

require_relative "../lib/aljam3"
require "digest"

plan = ARGV.fetch(0, "current")
path = ARGV.fetch(1, ".cache/benchmark/full/library.sqlite3")
runs = Integer(ARGV.fetch(2, "3"))
abort "Use scan or current, an existing fixture, and a positive run count" unless %w[scan current].include?(plan) && File.file?(path) && runs.positive?
temporary = File.join(File.dirname(File.expand_path(path)), "tmp")
FileUtils.mkdir_p(temporary)
ENV["SQLITE_TMPDIR"] = temporary
$stdout.sync = true

store = Aljam3::Store.new(path, background: false)
db = store.instance_variable_get(:@db)
target = store.preference("benchmark:pages")
raise "Incomplete or unmarked fixture" unless target && db.get_first_value("SELECT max(id) FROM pages") == target
manifest = JSON.parse(File.read(".cache/benchmark/source/manifest.json"))
texts = manifest.fetch("samples").flat_map { |sample| File.read(sample.fetch("path")).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
db.execute("CREATE VIRTUAL TABLE temp.samples USING fts5(content, tokenize='sqlite_tokenizer_ar disable_stopwords')")
db.transaction { texts.each_with_index { |text, i| db.execute("INSERT INTO samples(rowid, content) VALUES (?, ?)", [i + 1, text]) } }
search = Aljam3::Store::Search.new(db)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
report = { plan:, pages: target, runs:, recorded_at: Time.now.utc.iso8601, trials: {},
  fixture: "61 matching pages spaced across the entire repeated-OCR fixture; excerpt-only timings, without ranking" }

begin
  ["الله", "في", "الله الرحمن", "العلم العمل"].each do |query|
    match = Aljam3::Text.match_query(query)
    samples = db.execute("SELECT rowid FROM samples WHERE samples MATCH ?", [match]).map { |row| row.fetch("rowid") - 1 }.to_set
    ids = Array.new(61) do |index|
      first = 1 + index * (target - texts.size - 1) / 60
      (first...(first + texts.size)).find { |id| samples.include?((id * 7919) % texts.size) }
    end
    digest = nil
    times = Array.new(runs) do
      started = clock.call
      rows = db.transaction do
        if plan == "current"
          search.send(:pages_with_excerpts, match, ids)
        else
          db.execute(<<~SQL, [match, *ids.minmax, JSON.generate(ids)])
            SELECT p.id, p.file_id, p.number, p.content, b.data, snippet(pages_fts, 0, '', '', '…', 42) AS excerpt
            #{Aljam3::Store::Search::JOIN} WHERE pages_fts MATCH ? AND pages_fts.rowid BETWEEN ? AND ?
            AND +pages_fts.rowid IN (SELECT value FROM json_each(?))
          SQL
        end
      end
      elapsed = (clock.call - started) * 1000
      raise "Wrong result IDs" unless rows.map { |row| row.fetch("id") }.sort == ids
      actual = Digest::SHA256.hexdigest(JSON.generate(rows.sort_by { |row| row.fetch("id") }.map { |row| row.values_at("id", "excerpt") }))
      digest ||= actual
      raise "Excerpts changed between runs" unless actual == digest
      puts JSON.generate(plan:, query:, ms: elapsed.round(2))
      elapsed
    end
    report[:trials][query] = { first_ms: times.first.round(2), median_ms: times.sort[runs / 2].round(2), max_ms: times.max.round(2), ids:, excerpts_sha256: digest }
    File.write(File.join(File.dirname(path), "excerpts-#{plan}.json"), JSON.pretty_generate(report))
  end
ensure
  store.close
end
