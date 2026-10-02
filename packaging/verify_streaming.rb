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

  def self.call(file:, local_path:)
    http = HTTP.new
    source = Aljam3::RemotePDF.new(file.fetch("urls").fetch("pdf"), http:)
    Dir.mktmpdir("aljam3-streaming-") do |cache|
      pdf = Aljam3::PDF.new(cache:)
      [1, 72].each do |page|
        remote = pdf.render(source, page:, width: 400)
        local = pdf.render(local_path, page:, width: 400)
        raise "Streamed PDF page differs from local page" unless File.binread(remote.path) == File.binread(local.path)
        raise "Online reader fetched the entire test PDF" unless http.bytes < source.size
      end
      before = http.requests
      pdf.render(source, page: 72, width: 400)
      raise "Cached PDF page repeated network requests" unless http.requests == before
    end
    { bytes_fetched: http.bytes, file_bytes: source.size, range_requests: http.requests }
  ensure
    http&.close
  end
end
