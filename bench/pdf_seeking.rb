# frozen_string_literal: true

# mise run benchmark-pdf -- BOOK_ID FILE_ID PAGE [PAGE ...]
# Only requested PDF ranges are fetched; no full reference download is made.
require "json"
require "tmpdir"
require_relative "../lib/aljam3/api"
require_relative "../lib/aljam3/pdf"
require_relative "../packaging/verify_streaming"

book_id, file_id, *pages = ARGV.map { |value| Integer(value) }
abort "Usage: mise run benchmark-pdf -- BOOK_ID FILE_ID PAGE [PAGE ...]" unless book_id && file_id && pages.any?
book = Aljam3::API.new.book(book_id)
file = book.fetch("files").find { |item| item.fetch("id") == file_id }
abort "File #{file_id} does not belong to book #{book_id}." unless file

results = pages.map do |page|
  http = StreamingVerification::HTTP.new
  begin
    Dir.mktmpdir("aljam3-seek-") do |directory|
      source = Aljam3::RemotePDF.new(file.fetch("urls").fetch("pdf"), http:)
      pdf = Aljam3::PDF.new(cache: directory)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pdf.render(source, page:, width: 760)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      bytes = http.bytes
      pdf.render(source, page:, width: 760)
      { page:, file_bytes: source.size, bytes_fetched: bytes, range_requests: http.requests,
        percent_fetched: (100.0 * bytes / source.size).round(2), seconds: seconds.round(2),
        cached_reread_bytes: http.bytes - bytes }
    end
  ensure
    http.close
  end
end

puts JSON.pretty_generate({ book_id:, file_id:, title: book.fetch("title"),
  pdfium: File.read(File.expand_path("../vendor/pdfium/VERSION", __dir__)).strip, results: })
