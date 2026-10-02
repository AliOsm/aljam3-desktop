# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require "json"

module Aljam3
  class ConnectionError < StandardError; end
  class ResponseError < StandardError
    attr_reader :status

    def initialize(status)
      @status = status.to_i
      super("The library returned HTTP #{@status}.")
    end
  end

  class HTTP
    NETWORK_ERRORS = [SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ENETDOWN, Errno::ETIMEDOUT, Errno::EPIPE].freeze

    def get(url)
      request(url, headers: { "Accept" => "application/json" }) { |response| response.body }
    end

    def download(url, destination, validate_pdf: true, resume: false, check: -> {}, &progress)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.part"
      metadata = "#{temporary}.json"
      saved = JSON.parse(File.read(metadata)) if resume && File.file?(metadata)
      offset = resume && saved&.fetch("url") == url && saved["validator"] && File.file?(temporary) ? File.size(temporary) : 0
      headers = { "Accept-Encoding" => "identity" }
      headers.merge!("Range" => "bytes=#{offset}-", "If-Range" => saved.fetch("validator")) if offset.positive?
      check.call
      request(url, headers:, timeout: 8) do |response|
        partial = response.code == "206"
        expected = response["content-length"] && Integer(response["content-length"])
        if partial
          range = response["content-range"]&.match(/\Abytes (\d+)-(\d+)\/(\d+)\z/)
          unless range && range[1].to_i == offset && range[2].to_i + 1 == range[3].to_i && (!expected || expected == range[3].to_i - offset)
            raise ResponseError.new(416), "Invalid partial download response."
          end
          expected = range[3].to_i
        end
        received = partial ? offset : 0
        validator = response["etag"] unless response["etag"]&.start_with?("W/")
        validator ||= response["last-modified"]
        FileUtils.rm_f(metadata) unless partial
        last_update = 0
        File.open(temporary, partial ? "ab" : "wb") do |file|
          if resume
            File.write("#{metadata}.tmp", JSON.generate(url:, validator:))
            File.rename("#{metadata}.tmp", metadata)
          end
          response.read_body do |chunk|
            check.call
            file.write(chunk)
            received += chunk.bytesize
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - last_update >= 0.15
              progress&.call(received, expected)
              last_update = now
            end
          end
        end
        raise ConnectionError, "The download ended before the complete file arrived." if expected && received != expected
        progress&.call(received, expected)
      end
      if validate_pdf && !File.binread(temporary, 1024).include?("%PDF-")
        FileUtils.rm_f([temporary, metadata])
        raise ResponseError.new(422), "The download is not a PDF."
      end

      check.call
      File.rename(temporary, destination)
      FileUtils.rm_f(metadata)
      destination
    rescue ResponseError => error
      if error.status == 416 && offset&.positive?
        FileUtils.rm_f([temporary, metadata])
        return download(url, destination, validate_pdf:, resume:, check:, &progress)
      end
      raise
    ensure
      FileUtils.rm_f([temporary, metadata].compact) unless resume
    end

    private

    def request(url, headers: {}, timeout: 8, redirects: 5, &block)
      uri = URI(url)
      raise ArgumentError, "Expected an HTTP(S) URL." unless %w[http https].include?(uri.scheme)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 3
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri, { "User-Agent" => "Aljam3Desktop/0.1", **headers })
      http.request(request) do |response|
        case response
        when Net::HTTPSuccess then return block.call(response)
        when Net::HTTPRedirection
          raise ResponseError, response.code if redirects.zero? || !response["location"]

          return request(URI.join(uri, response["location"]).to_s, headers:, timeout:, redirects: redirects - 1, &block)
        else raise ResponseError, response.code
        end
      end
    rescue *NETWORK_ERRORS => error
      raise ConnectionError, error.message
    end
  end
end
