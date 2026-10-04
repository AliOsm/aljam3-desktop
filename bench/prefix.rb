# frozen_string_literal: true

# An index experiment on the disposable benchmark database, never user data.
require_relative "../lib/aljam3"

path = ARGV.fetch(0, ".cache/benchmark/library.sqlite3")
abort "Expected an existing benchmark fixture" unless File.file?(path)
prefixes = ARGV.fetch(1, "2 3 4")
abort "Expected space-separated positive prefix lengths" unless prefixes.match?(/\A[1-9](?: [1-9])*\z/)
store = Aljam3::Store.new(path, background: false)
db = store.instance_variable_get(:@db)
raise "Not a marked benchmark fixture" unless store.preference("benchmark:pages")
$stdout.sync = true
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
started = clock.call
db.execute("CREATE VIRTUAL TABLE IF NOT EXISTS trial_fts USING fts5(content, content='pages', content_rowid='id', tokenize='sqlite_tokenizer_ar disable_stopwords', prefix='#{prefixes}')")
db.execute("INSERT INTO trial_fts(trial_fts) VALUES ('rebuild')")
db.execute("INSERT INTO trial_fts(trial_fts) VALUES ('optimize')")
puts JSON.generate(build_seconds: clock.call - started)
%w[الله في العلم].each do |term|
  %w[pages_fts trial_fts].each do |table|
    3.times do
      started = clock.call
      ids = db.execute("SELECT rowid FROM #{table} WHERE #{table} MATCH ? ORDER BY rank LIMIT 13", [Aljam3::Text.match_query(term)]).map { |row| row.fetch("rowid") }
      puts JSON.generate(table:, term:, ms: ((clock.call - started) * 1000).round(2), ids:)
    end
  end
end
puts JSON.generate(db.execute("SELECT name, sum(pgsize) AS bytes FROM dbstat WHERE name LIKE '%fts%' GROUP BY name"))
store.close
