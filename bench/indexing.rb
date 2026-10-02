# frozen_string_literal: true
require_relative '../lib/aljam3'
require 'tmpdir'

source = SQLite3::Database.new('.cache/benchmark/library.sqlite3', readonly: true, results_as_hash: true)
rows = source.execute('SELECT id,number,content FROM pages LIMIT 100000')
rows.each_with_index { |row,index| row['number'] = index + 1 }
$stdout.sync = true
Dir.mktmpdir('aljam3-indexing') do |directory|
  [[8,4],[64,4],[64,8]].each do |cache,merge|
    store = Aljam3::Store.new(File.join(directory, "#{cache}-#{merge}.sqlite3"), background: false)
    db = store.instance_variable_get(:@db)
    db.execute("PRAGMA cache_size=-#{cache*1024}")
    db.execute("INSERT INTO pages_fts(pages_fts,rank) VALUES ('automerge',?)",[merge])
    store.prepare_download({'id'=>1, 'title'=>'benchmark', 'files'=>[{'id'=>1,'pages_count'=>rows.size}]})
    time=Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows.each_slice(500) { |batch| store.add_pages(1,batch) }
    elapsed=Process.clock_gettime(Process::CLOCK_MONOTONIC)-time
    puts JSON.generate(cache_mib:cache,automerge:merge,pages:rows.size,seconds:elapsed,pps:rows.size/elapsed)
    store.close
  end
end
