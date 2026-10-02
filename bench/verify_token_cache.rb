# frozen_string_literal: true
require_relative '../lib/aljam3'
require 'tmpdir'

original = ENV.fetch('SQLITE_TOKENIZER_AR_EXTENSION')
ENV['ALJAM3_BENCH_TOKENIZER'] = original
manifest = JSON.parse(File.read('.cache/benchmark/source/manifest.json'))
texts = manifest.fetch('samples').flat_map { |sample| File.read(sample.fetch('path')).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1) }
Dir.mktmpdir('aljam3-token-cache') do |directory|
  [original, File.expand_path(ARGV.fetch(0, '.cache/benchmark/token_cache.so'))].each_with_index do |extension, index|
    SQLite3::Database.new(File.join(directory, "#{index}.sqlite3"), extensions: [extension]) do |db|
      db.execute("CREATE VIRTUAL TABLE pages_fts USING fts5(content, tokenize='sqlite_tokenizer_ar disable_stopwords')")
      db.transaction do
        2.times do |copy|
          texts.each_with_index { |text, row| db.execute('INSERT INTO pages_fts(rowid,content) VALUES (?,?)', [copy * texts.size + row + 1, "#{text}\n#{copy * texts.size + row + 1}"]) }
        end
      end
      db.execute("CREATE VIRTUAL TABLE vocabulary USING fts5vocab(pages_fts, 'instance')")
    end
  end
  SQLite3::Database.new(File.join(directory, '0.sqlite3'), extensions: [original]) do |db|
    db.execute('ATTACH DATABASE ? AS cached', [File.join(directory, '1.sqlite3')])
    %w[main cached].permutation.each do |left,right|
      differences = db.get_first_value("SELECT count(*) FROM (SELECT * FROM #{left}.vocabulary EXCEPT SELECT * FROM #{right}.vocabulary)")
      raise "Token positions differ (#{differences})" unless differences.zero?
    end
    puts JSON.generate(verified: true, distinct_samples: texts.size, indexed_pages: texts.size * 2,
      token_occurrences: db.get_first_value('SELECT count(*) FROM vocabulary'))
  end
end
