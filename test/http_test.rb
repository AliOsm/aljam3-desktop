# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HTTPTest < Minitest::Test
  include Fixtures
  def with_server(*responses, keep_alive: false)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = nil
      responses.each do |response|
        socket ||= server.accept
        request = socket.gets
        while (header = socket.gets)
          break if header == "\r\n"
          request += header
        end
        socket.write(response.respond_to?(:call) ? response.call(request) : response)
        unless keep_alive
          socket.close
          socket = nil
        end
      end
    ensure
      socket&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.kill&.join
    server&.close
  end

  def response(body, status: "200 OK", headers: {})
    headers = { "Content-Length" => body.bytesize, "Connection" => "close", **headers }
    "HTTP/1.1 #{status}\r\n#{headers.map { |key, value| "#{key}: #{value}\r\n" }.join}\r\n#{body}"
  end

  def test_redirected_pdf_is_saved_atomically
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      pdf = "%PDF-1.7\nfixture"
      with_server(response("", status: "302 Found", headers: { "Location" => "/file.pdf" }), response(pdf)) do |url|
        Aljam3::HTTP.new.download("#{url}/redirect", target) do |_bytes, _total|
          refute File.exist?(target)
        end
      end
      assert_equal pdf, File.binread(target)
      refute File.exist?("#{target}.part")
    end
  end

  def test_truncated_download_is_not_published
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      with_server(response("%PDF-truncated", headers: { "Content-Length" => 1000 })) do |url|
        assert_raises(Aljam3::ConnectionError) { Aljam3::HTTP.new.download(url, target) }
      end
      refute File.exist?(target)
      refute File.exist?("#{target}.part")
    end
  end

  def test_successful_http_response_containing_html_is_not_accepted_as_pdf
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      with_server(response("<html>Unavailable</html>")) do |url|
        assert_raises(Aljam3::ResponseError) { Aljam3::HTTP.new.download(url, target) }
      end
      refute File.exist?(target)
    end
  end

  def test_service_errors_preserve_http_status
    with_server(response("Busy", status: "503 Unavailable")) do |url|
      error = assert_raises(Aljam3::ResponseError) { Aljam3::HTTP.new.get(url) }
      assert_equal 503, error.status
    end
  end

  def test_api_rejects_non_json_responses
    with_server(response("<html>maintenance</html>")) do |url|
      error = assert_raises(Aljam3::ResponseError) { Aljam3::API.new(base_url: url, interval: 0).search("العلم") }
      assert_equal 502, error.status
    end
  end

  def test_book_search_encodes_the_api_book_filter
    request = nil
    with_server(->(line) { request = line; response('{"pages":[]}') }) do |url|
      Aljam3::API.new(base_url: url, interval: 0).search("العلم", book_id: 42)
    end
    query = URI.decode_www_form(URI(request.split[1]).query).to_h
    assert_equal "42", query.fetch("books[]")
    assert_equal "العلم", query.fetch("q")
    refute query.key?("categories[]")
  end

  def test_text_search_encodes_all_filters
    request = nil
    with_server(->(line) { request = line; response('{"pages":[]}') }) do |url|
      Aljam3::API.new(base_url: url, interval: 0).search("العلم", category: 3, author: 12, library: 2)
    end
    query = URI.decode_www_form(URI(request.split[1]).query).to_h
    assert_equal "3", query.fetch("categories[]")
    assert_equal "12", query.fetch("authors[]")
    assert_equal "2", query.fetch("library")
  end

  def test_scoped_books_restore_the_metadata_omitted_by_the_api
    data = { "id" => 4, "name" => "النووي", "books" => [book.reject { |key, _| key == "author" }] }
    with_server(response(JSON.generate(data))) do |url|
      result = Aljam3::API.new(base_url: url, interval: 0).books(author: 4)
      assert_equal "النووي", result.fetch("books").first.dig("author", "name")
    end
  end

  def test_individual_text_export_is_atomic_without_pdf_validation
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.txt")
      with_server(response("نص الكتاب")) do |url|
        Aljam3::HTTP.new.download(url, target, validate_pdf: false)
      end
      assert_equal "نص الكتاب", File.read(target)
      refute File.exist?("#{target}.part")
    end
  end

  def test_resumes_an_interrupted_pdf_using_a_range_and_a_validator
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      pdf = "%PDF-1.7\ncomplete book"
      prefix = pdf[0, 10]
      tail = pdf[10..]
      resumed = nil
      first = response(prefix, headers: { "Content-Length" => pdf.bytesize, "ETag" => '"edition-1"' })
      second = ->(request) do
        resumed = request
        response(tail, status: "206 Partial Content", headers: { "Content-Range" => "bytes 10-#{pdf.bytesize - 1}/#{pdf.bytesize}", "ETag" => '"edition-1"' })
      end
      with_server(first, second) do |url|
        http = Aljam3::HTTP.new
        assert_raises(Aljam3::ConnectionError) { http.download(url, target, resume: true) }
        refute File.exist?(target)
        assert_equal prefix, File.binread("#{target}.part")
        http.download(url, target, resume: true)
      end
      assert_match(/Range: bytes=10-/i, resumed)
      assert_match(/If-Range: "edition-1"/i, resumed)
      assert_equal pdf, File.binread(target)
      refute File.exist?("#{target}.part.json")
    end
  end

  def test_server_ignoring_range_restarts_without_appending_to_the_partial_pdf
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      pdf = "%PDF-1.7\nnew edition"
      first = response("%PDF-old", headers: { "Content-Length" => 1000, "ETag" => '"old"' })
      with_server(first, response(pdf)) do |url|
        http = Aljam3::HTTP.new
        assert_raises(Aljam3::ConnectionError) { http.download(url, target, resume: true) }
        http.download(url, target, resume: true)
      end
      assert_equal pdf, File.binread(target)
    end
  end

  def test_changed_validator_in_partial_response_restarts_without_mixing_editions
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      old_pdf = "%PDF-1.7\nold edition"
      new_pdf = "%PDF-1.7\nnew content"
      first = response(old_pdf[0, 12], headers: { "Content-Length" => old_pdf.bytesize, "ETag" => '"old"' })
      changed = response(new_pdf[12..], status: "206 Partial Content", headers: {
        "Content-Range" => "bytes 12-#{new_pdf.bytesize - 1}/#{new_pdf.bytesize}", "ETag" => '"new"'
      })
      restarted = nil
      with_server(first, changed, ->(request) { restarted = request; response(new_pdf) }) do |url|
        http = Aljam3::HTTP.new
        assert_raises(Aljam3::ConnectionError) { http.download(url, target, resume: true) }
        http.download(url, target, resume: true)
      end
      assert_equal new_pdf, File.binread(target)
      refute_nil restarted, "A changed edition must be downloaded from its beginning"
      refute_match(/^Range:/i, restarted)
    end
  end

  def test_damaged_resume_metadata_restarts_the_download
    ["{", "[]", "null", "{}", :invalid_validator].each do |metadata|
      Dir.mktmpdir do |directory|
        target = File.join(directory, "book.pdf")
        pdf = "%PDF-1.7\ncomplete book"
        request = nil
        with_server(->(value) { request = value; response(pdf) }) do |url|
          metadata = JSON.generate(url:, validator: 123) if metadata == :invalid_validator
          File.binwrite("#{target}.part", "%PDF-old")
          File.write("#{target}.part.json", metadata)
          Aljam3::HTTP.new.download(url, target, resume: true)
        end
        assert_equal pdf, File.binread(target)
        refute_match(/^Range:/i, request)
        refute File.exist?("#{target}.part.json")
      end
    end
  end

  def test_invalid_content_range_retries_from_the_start
    Dir.mktmpdir do |directory|
      target = File.join(directory, "book.pdf")
      pdf = "%PDF-1.7\nnew edition"
      first = response("%PDF-old", headers: { "Content-Length" => 1000, "ETag" => '"old"' })
      invalid = response("bad", status: "206 Partial Content", headers: { "Content-Range" => "bytes 1-3/4" })
      with_server(first, invalid, response(pdf)) do |url|
        http = Aljam3::HTTP.new
        assert_raises(Aljam3::ConnectionError) { http.download(url, target, resume: true) }
        http.download(url, target, resume: true)
      end
      assert_equal pdf, File.binread(target)
    end
  end

  def test_pdf_range_follows_redirects_and_accepts_a_short_final_block
    request = nil
    part = response("tail", status: "206 Partial Content", headers: { "Content-Range" => "bytes 100-103/104", "ETag" => '"v1"' })
    with_server(response("", status: "302 Found", headers: { "Location" => "/file.pdf" }), ->(value) { request = value; part }) do |url|
      result = Aljam3::HTTP.new.read_range(url, offset: 100, length: 64, validator: '"v1"')
      assert_equal "tail", result.bytes
      assert_equal 104, result.size
      assert_equal "#{url}/file.pdf", result.url
      assert_equal '"v1"', result.validator
    end
    assert_match(/Range: bytes=100-163/i, request)
    assert_match(/If-Range: "v1"/i, request)
    assert_match(/Accept-Encoding: identity/i, request)
  end

  def test_pdf_range_refuses_a_full_response_without_waiting_for_its_body
    # The server sends headers, but never sends the promised full PDF body.
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      while (header = socket.gets)
        break if header == "\r\n"
      end
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 500000000\r\n\r\n")
      socket.read
    ensure
      socket&.close
    end
    Timeout.timeout(2) do
      assert_raises(Aljam3::RangeUnsupportedError) do
        Aljam3::HTTP.new.read_range("http://127.0.0.1:#{server.addr[1]}", offset: 0, length: 64)
      end
    end
  ensure
    thread&.kill&.join
    server&.close
  end

  def test_pdf_ranges_reuse_the_connection_between_page_reads
    headers = { "Connection" => "keep-alive", "ETag" => '"v1"' }
    first = response("head", status: "206 Partial Content", headers: headers.merge("Content-Range" => "bytes 0-3/8"))
    second = response("tail", status: "206 Partial Content", headers: headers.merge("Content-Range" => "bytes 4-7/8"))
    http = Aljam3::HTTP.new
    Timeout.timeout(2) do
      with_server(first, second, keep_alive: true) do |url|
        assert_equal "head", http.read_range(url, offset: 0, length: 4).bytes
        assert_equal "tail", http.read_range(url, offset: 4, length: 4, validator: '"v1"').bytes
      end
    end
  ensure
    http&.close
  end

  def test_pdf_ranges_reject_wrong_offsets_compression_and_unexpected_body_lengths
    cases = [
      response("abcd", status: "206 Partial Content", headers: { "Content-Range" => "bytes 1-4/10" }),
      response("abcd", status: "206 Partial Content", headers: { "Content-Range" => "bytes 0-3/10", "Content-Encoding" => "gzip" }),
      response("abcde", status: "206 Partial Content", headers: { "Content-Range" => "bytes 0-3/10" })
    ]
    cases.each do |value|
      with_server(value) do |url|
        assert_raises(Aljam3::ResponseError) { Aljam3::HTTP.new.read_range(url, offset: 0, length: 4) }
      end
    end
    with_server(response("ab", status: "206 Partial Content", headers: { "Content-Range" => "bytes 0-3/10", "Content-Length" => 4 })) do |url|
      assert_raises(Aljam3::ConnectionError) { Aljam3::HTTP.new.read_range(url, offset: 0, length: 4) }
    end
  end

  def test_pdf_ranges_reject_a_changed_edition_instead_of_mixing_bytes
    [response("new edition"), response("abcd", status: "206 Partial Content", headers: { "Content-Range" => "bytes 0-3/10", "ETag" => '"v2"' })].each do |value|
      with_server(value) do |url|
        assert_raises(Aljam3::RemoteFileChangedError) { Aljam3::HTTP.new.read_range(url, offset: 0, length: 4, validator: '"v1"') }
      end
    end
  end
end
