# frozen_string_literal: true

require "net/http"
require "uri"
require "fileutils"
require "json"

module Aljam3
  class ConnectionError < StandardError; end
  class RangeUnsupportedError < StandardError; end
  class RemoteFileChangedError < StandardError; end
  class ResponseError < StandardError
    attr_reader :status

    def initialize(status)
      @status = status.to_i
      super("The library returned HTTP #{@status}.")
    end
  end

  class HTTP
    Range = Data.define(:bytes, :size, :validator, :url)
    NETWORK_ERRORS = [SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ENETDOWN, Errno::ETIMEDOUT, Errno::EPIPE].freeze

    def get(url)
      request(url, headers: { "Accept" => "application/json" }) { |response| response.body }
    end

    def read_range(url, offset:, length:, validator: nil, check: -> {})
      raise ArgumentError, "Invalid byte range." unless offset >= 0 && length.positive?

      headers = { "Range" => "bytes=#{offset}-#{offset + length - 1}", "Accept-Encoding" => "identity" }
      headers["If-Range"] = validator if validator
      request(url, headers:, persistent: true) do |response|
        check.call
        if response.code == "200"
          raise RemoteFileChangedError, "The PDF changed. Please retry." if validator

          raise RangeUnsupportedError, "This host does not support reading PDF sections."
        end
        range = response["content-range"]&.match(/\Abytes (\d+)-(\d+)\/(\d+)\z/)
        unless response.code == "206" && range && range[1].to_i == offset &&
            range[2].to_i == [offset + length, range[3].to_i].min - 1 &&
            range[3].to_i > offset && [nil, "identity"].include?(response["content-encoding"])
          raise ResponseError.new(502), "Invalid PDF byte range."
        end
        current = response["etag"] unless response["etag"]&.start_with?("W/")
        current ||= response["last-modified"]
        raise RemoteFileChangedError, "The PDF changed. Please retry." if validator && current != validator

        expected = range[2].to_i - offset + 1
        bytes = +"".b
        response.read_body do |chunk|
          check.call
          raise ResponseError.new(502), "PDF range exceeded its requested size." if bytes.bytesize + chunk.bytesize > expected

          bytes << chunk
        end
        raise ConnectionError, "The PDF section was interrupted." unless bytes.bytesize == expected

        Range.new(bytes, range[3].to_i, current, response.uri.to_s)
      end
    end

    def close
      @range_http.finish if @range_http&.started?
      @range_http = @range_origin = nil
    end

    # PDF page dictionaries can be scattered across a flat page tree. Fetch
    # their known byte ranges concurrently with a separate connection per worker.
    # Publish no partial batch if a request fails or navigation cancels the work.
    def read_ranges(url, ranges:, validator: nil, check: -> {})
      jobs, completed, results, failure = Queue.new, Queue.new, Array.new(ranges.length), nil
      ranges.each_with_index { |range, index| jobs << [index, range] }
      jobs.close
      batch_check = -> { raise failure if failure; check.call }
      workers = [ranges.length, 4].min.times.map do
        Thread.new do
          client = HTTP.new
          while (job = jobs.pop)
            batch_check.call
            index, (offset, length) = job
            results[index] = client.read_range(url, offset:, length:, validator:, check: batch_check)
          end
        rescue StandardError => error
          failure ||= error
        ensure
          begin
            client&.close
          rescue StandardError => error
            failure ||= error
          ensure
            completed << true
          end
        end
      end
      workers.length.times do
        completed.pop
        raise failure if failure
      end
      workers.each(&:join)
      batch_check.call
      results
    ensure
      workers&.each { |worker| worker.kill.join if worker.alive? }
    end

    def download(url, destination, validate_pdf: true, resume: false, check: -> {}, &progress)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.part"
      metadata = "#{temporary}.json"
      saved = resume_metadata(metadata) if resume
      offset = saved && saved["url"] == url && File.file?(temporary) ? File.size(temporary) : 0
      headers = { "Accept-Encoding" => "identity" }
      headers.merge!("Range" => "bytes=#{offset}-", "If-Range" => saved.fetch("validator")) if offset.positive?
      check.call
      request(url, headers:, timeout: 8) do |response|
        partial = response.code == "206"
        expected = response["content-length"] && Integer(response["content-length"])
        validator = response["etag"] unless response["etag"]&.start_with?("W/")
        validator ||= response["last-modified"]
        if partial
          range = response["content-range"]&.match(/\Abytes (\d+)-(\d+)\/(\d+)\z/)
          same_file = !offset.positive? || validator == saved.fetch("validator")
          unless same_file && range && range[1].to_i == offset && range[2].to_i + 1 == range[3].to_i && (!expected || expected == range[3].to_i - offset)
            raise ResponseError.new(416), "Invalid partial download response."
          end
          expected = range[3].to_i
        end
        received = partial ? offset : 0
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

    def resume_metadata(path)
      data = JSON.parse(File.read(path))
      data if data.is_a?(Hash) && data["validator"].is_a?(String) && !data["validator"].empty?
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def request(url, headers: {}, timeout: 8, redirects: 5, persistent: false, &block)
      uri = URI(url)
      raise ArgumentError, "Expected an HTTP(S) URL." unless %w[http https].include?(uri.scheme)

      http = connection(uri, timeout:, persistent:)
      request = Net::HTTP::Get.new(uri, { "User-Agent" => "Aljam3Desktop/0.1", **headers })
      result = redirect = nil
      http.request(request) do |response|
        case response
        when Net::HTTPSuccess then result = block.call(response)
        when Net::HTTPRedirection
          raise ResponseError, response.code if redirects.zero? || !response["location"]

          redirect = URI.join(uri, response["location"]).to_s
        else raise ResponseError, response.code
        end
      end
      return request(redirect, headers:, timeout:, redirects: redirects - 1, persistent:, &block) if redirect

      result
    rescue *NETWORK_ERRORS => error
      raise ConnectionError, error.message
    end

    def connection(uri, timeout:, persistent:)
      origin = [uri.scheme, uri.host, uri.port]
      return @range_http if persistent && @range_origin == origin && @range_http&.started?

      close if persistent
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 3
      http.read_timeout = http.write_timeout = timeout
      http.max_retries = 0
      if persistent
        http.start
        @range_http, @range_origin = http, origin
      end
      http
    end
  end
end
