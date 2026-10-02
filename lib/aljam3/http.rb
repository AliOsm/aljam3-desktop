# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"

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

    def download(url, destination, validate_pdf: true, &progress)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.part"
      request(url, headers: { "Accept-Encoding" => "identity" }, timeout: 30) do |response|
        expected = response["content-length"]&.to_i
        received = 0
        last_update = 0
        File.open(temporary, "wb") do |file|
          response.read_body do |chunk|
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
      end
      if validate_pdf && !File.binread(temporary, 1024).include?("%PDF-")
        raise ResponseError.new(422), "The download is not a PDF."
      end

      File.rename(temporary, destination)
      destination
    ensure
      FileUtils.rm_f(temporary) if temporary
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
