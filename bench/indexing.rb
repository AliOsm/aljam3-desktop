# frozen_string_literal: true

require_relative "../lib/aljam3"
require "tmpdir"

temporary = File.expand_path("../.cache/benchmark/tmp", __dir__)
FileUtils.mkdir_p(temporary)
ENV["SQLITE_TMPDIR"] = temporary

manifest = JSON.parse(File.read(".cache/benchmark/source/manifest.json"))
texts = manifest.fetch("samples").flat_map { |sample| File.read(sample.fetch("path")).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
rows = Array.new(100_000) do |index|
  id = index + 1
  { "id" => id, "number" => id, "content" => "#{texts[(id * 7919) % texts.size]}\n#{id}" }
end
$stdout.sync = true
expected = nil
Dir.mktmpdir("aljam3-indexing", temporary) do |directory|
  [["previous", 8, 4], ["bulk", 8, 4], ["bulk", 64, 4], ["bulk", 64, 8]].each do |method, cache, merge|
    store = Aljam3::Store.new(File.join(directory, "#{method}-#{cache}-#{merge}.sqlite3"), background: false)
    db = store.instance_variable_get(:@db)
    db.execute("PRAGMA cache_size=-#{cache * 1024}")
    db.execute("INSERT INTO pages_fts(pages_fts,rank) VALUES ('automerge',?)", [merge])
    store.prepare_download({ "id" => 1, "title" => "benchmark", "files" => [{ "id" => 1, "pages_count" => rows.size }] })
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows.each_slice(500) do |batch|
      if method == "previous"
        # Retain the old per-row insert here solely as a reproducible baseline.
        db.transaction do
          db.prepare("INSERT OR IGNORE INTO pages(id,file_id,number,content) VALUES (?,?,?,?)") do |statement|
            batch.each { |page| statement.execute(page.fetch("id"), 1, page.fetch("number"), page.fetch("content")) }
          end
          first, last = batch.map { |page| page.fetch("id") }.minmax
          db.execute("UPDATE files SET first_page_id=min(coalesce(first_page_id,?),?), last_page_id=max(coalesce(last_page_id,?),?) WHERE id=?", [first, first, last, last, 1])
        end
      else
        store.add_pages(1, batch)
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    store.complete_download(1)
    matches = db.get_first_value("SELECT count(*) FROM pages_fts WHERE pages_fts MATCH ?", [Aljam3::Text.match_query("الله")])
    results = store.search("الله").fetch("pages").map { |hit| hit.fetch("id") }
    actual = [store.page_count(1), matches, results]
    expected ||= actual
    raise "Indexing methods produced different results" unless actual == expected

    puts JSON.generate(method:, cache_mib: cache, automerge: merge, pages: rows.size, seconds: elapsed, pages_per_second: rows.size / elapsed, matches:)
    store.close
  end
end
