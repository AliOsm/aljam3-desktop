# frozen_string_literal: true

# Run with `mise exec -- ruby bench/prepare.rb` (CSV is bundled with Ruby).
require "csv"
require "json"
require "digest"
require "fileutils"
require "uri"
require_relative "../lib/aljam3/http"

root = File.expand_path("../.cache/benchmark/source", __dir__)
FileUtils.mkdir_p(root)
http = Aljam3::HTTP.new
random = Random.new(42)
manifest = { libraries: [], samples: [] }
catalog = []
authors, categories = {}, {}
%w[prophet-mosque shamela-waqfeya waqfeya].each_with_index do |name, library|
  base = "https://huggingface.co/datasets/ieasybooks-org/#{name}-library/resolve/main"
  index = File.join(root, "#{name}-index.tsv")
  http.download("#{base}/index.tsv", index, validate_pdf: false) unless File.file?(index)
  rows = CSV.read(index, col_sep: "\t", headers: true)
  manifest[:libraries] << { name:, books: rows.size, pages: rows.sum { |row| Integer(row.fetch("pages")) }, index_sha256: Digest::SHA256.file(index).hexdigest }
  rows.each do |row|
    author = row.fetch("author") || ""
    category = row.fetch("category") || ""
    authors[author] ||= authors.size + 1
    categories[category] ||= categories.size + 1
    catalog << { "id" => catalog.size + 1, "title" => row.fetch("title"), "pages_count" => Integer(row.fetch("pages")), "files_count" => 1,
      "author" => { "id" => authors.fetch(author), "name" => author }, "category" => { "id" => categories.fetch(category), "name" => category },
      "library" => { "id" => library + 1, "name" => name } }
  end
  chosen = []
  rows.select { |row| (150..600).cover?(Integer(row.fetch("pages"))) }.shuffle(random:).each do |row|
    next if chosen.include?(row["category"])

    paths = JSON.parse(row.fetch("txt_paths").sub(/\A\['/, '["').gsub("', '", '", "').sub(/'\]\z/, '"]'))
    next if paths.empty?

    path = paths.first.delete_prefix("./").split("/").map { |part| URI.encode_uri_component(part) }.join("/")
    url = "#{base}/#{path}"
    target = File.join(root, "#{Digest::SHA256.hexdigest(url)[0, 16]}.txt")
    http.download(url, target, validate_pdf: false) unless File.file?(target)
    pages = File.read(target).split(/\r?\nPAGE_SEPARATOR\r?\n/, -1)
    manifest[:samples] << { library: name, category: row["category"], title: row["title"], url:, path: target, pages: pages.size, bytes: File.size(target), sha256: Digest::SHA256.file(target).hexdigest }
    chosen << row["category"]
    puts "#{name}: #{chosen.size}/8 samples (#{pages.size} pages)"
    $stdout.flush
    break if chosen.size == 8
  end
end
File.write(File.join(root, "manifest.json"), JSON.pretty_generate(manifest))
File.write(File.join(root, "catalog.json"), JSON.generate(catalog))
puts JSON.pretty_generate(manifest[:libraries])
