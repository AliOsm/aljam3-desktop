# frozen_string_literal: true

require_relative "../lib/aljam3"
require_relative "bulk_pages"
require "tmpdir"

manifest = JSON.parse(File.read(".cache/benchmark/source/manifest.json"))
texts = manifest.fetch("samples").flat_map { |sample| File.read(sample.fetch("path")).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
count = texts.size * 2
Dir.mktmpdir("aljam3-bulk-pages") do |directory|
  %w[ruby sql].each do |mode|
    store = Aljam3::Store.new(File.join(directory, "#{mode}.sqlite3"), background: false)
    db = store.instance_variable_get(:@db)
    store.prepare_download({ "id" => 1, "title" => "fixture", "files" => [{ "id" => 17 }] })
    bulk = BulkPages.new(db, texts) if mode == "sql"
    count.times.each_slice(bulk ? count : 500) do |numbers|
      if bulk
        bulk.add(17, 23, numbers)
      else
        store.add_pages(17, numbers.map do |number|
          id = 23 + number + 1
          { "id" => id, "number" => number + 1, "content" => "#{texts[(id * 7919) % texts.size]}\n#{id}" }
        end)
      end
    end
    db.execute("CREATE VIRTUAL TABLE vocabulary USING fts5vocab(pages_fts, instance)")
    store.close
  end
  SQLite3::Database.new(File.join(directory, "ruby.sqlite3"), extensions: [ENV.fetch("SQLITE_TOKENIZER_AR_EXTENSION")]) do |db|
    db.execute("ATTACH DATABASE ? AS trial", [File.join(directory, "sql.sqlite3")])
    %w[pages files vocabulary].each do |table|
      %w[main trial].permutation.each do |left, right|
        differences = db.get_first_value("SELECT count(*) FROM (SELECT * FROM #{left}.#{table} EXCEPT SELECT * FROM #{right}.#{table})")
        raise "#{table} differs (#{differences})" unless differences.zero?
      end
    end
    puts JSON.generate(verified: true, indexed_pages: count, tables: %w[pages files vocabulary])
  end
end
