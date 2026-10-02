# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HTTPTest < Minitest::Test
  include Fixtures
  def with_server(*responses)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      responses.each do |response|
        socket = server.accept
        request = socket.gets
        while (header = socket.gets)
          break if header == "\r\n"
        end
        socket.write(response.respond_to?(:call) ? response.call(request) : response)
        socket.close
      end
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill&.join
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
    assert_raises(ArgumentError) { Aljam3::API.new.books(author: 4, category: 2) }
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
end
