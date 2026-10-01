# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class HTTPTest < Minitest::Test
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
end
