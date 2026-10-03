# frozen_string_literal: true

require "tmpdir"

module StreamingVerification
  class HTTP < Aljam3::HTTP
    attr_reader :bytes, :requests

    def initialize = @bytes = @requests = 0

    def read_range(...)
      result = super
      @bytes += result.bytes.bytesize
      @requests += 1
      result
    end
  end

  def self.call(file:, local_path:, pages: [1, 72], max_bytes: nil)
    http = HTTP.new
    source = Aljam3::RemotePDF.new(file.fetch("urls").fetch("pdf"), http:)
    Dir.mktmpdir("aljam3-streaming-") do |cache|
      pdf = Aljam3::PDF.new(cache:)
      pages.each do |page|
        remote = pdf.render(source, page:, width: 400)
        local = pdf.render(local_path, page:, width: 400)
        raise "Streamed PDF page differs from local page" unless File.binread(remote.path) == File.binread(local.path)
        raise "Online reader fetched the entire test PDF" unless http.bytes < source.size
        raise "PDF seeking exceeded its byte budget" if max_bytes && http.bytes > max_bytes
      end
      before = http.requests
      pdf.render(source, page: pages.last, width: 400)
      raise "Cached PDF page repeated network requests" unless http.requests == before
    end
    { bytes_fetched: http.bytes, file_bytes: source.size, range_requests: http.requests }
  ensure
    http&.close
  end

  # Full reference downloads happen only in this verification helper, so ranged
  # renders can be compared with local pixels. The app never calls this method.
  def self.distant_pages(api:)
    file = api.book(3435).fetch("files").find { |item| item.fetch("id") == 8291 }
    Dir.mktmpdir("aljam3-pdf-reference-") do |directory|
      local_path = File.join(directory, "book.pdf")
      Aljam3::HTTP.new.download(file.fetch("urls").fetch("pdf"), local_path)
      [104, 471].to_h do |page|
        [page, call(file:, local_path:, pages: [page], max_bytes: 1024 * 1024)]
      end
    end
  end
end
