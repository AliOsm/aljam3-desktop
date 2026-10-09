# frozen_string_literal: true

require "socket"
require "uri"
require "json"
require_relative "range_pdf"

class CategoryServer
  attr_accessor :hold_file, :hold_scan_page, :scan_error
  attr_reader :category, :books, :requests, :failed_files, :connection_failures

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @category = { "id" => 71, "name" => "أصول الفقه والقواعد الفقهية", "books_count" => 18 }
    @requests, @connections, @failed_files = [], [], []
    @connection_failures = Hash.new(0)
    names = ["الورقات في أصول الفقه", "الموافقات", "روضة الناظر", "إرشاد الفحول", "البحر المحيط", "الإحكام في أصول الأحكام"]
    @books = (1..18).map do |number|
      id = 970_000 + number
      files = (1..(number == 4 ? 2 : 1)).map do |part|
        file_id = id * 10 + part
        { "id" => file_id, "name" => "المجلد #{part}", "pages_count" => 2, "urls" => { "pdf" => "#{base}/pdf/#{file_id}" } }
      end
      { "id" => id, "title" => "#{names[(number - 1) % names.length]} · #{number}", "category" => @category,
        "author" => { "id" => id, "name" => "مؤلف الكتاب #{number}" }, "library" => { "id" => 1, "name" => "المكتبة الوقفية" },
        "files" => files, "files_count" => files.length, "pages_count" => files.length * 2 }
    end
    @pdf = RangePDF.document(pages: 2)
    @thread = Thread.new do
      loop do
        socket = @server.accept
        @connections << Thread.new(socket) do |client|
          begin
            target = client.gets.split[1]
            while (header = client.gets) && header != "\r\n"; end
            @requests << target
            uri = URI(target)
            file_id = uri.path[%r{\A/pdf/(\d+)\z}, 1]&.to_i
            if file_id && @connection_failures[file_id].positive?
              @connection_failures[file_id] -= 1
              next # Close before responding, like a dropped TLS/TCP connection.
            end
            params = URI.decode_www_form(uri.query.to_s).to_h
            body, status = response(uri.path, params)
            client.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
            if uri.path.start_with?("/pdf/") && @hold_file == uri.path.split("/").last.to_i
              midpoint = body.bytesize / 2
              client.write(body.byteslice(0, midpoint))
              sleep 0.005 while @hold_file == uri.path.split("/").last.to_i
              client.write(body.byteslice(midpoint..))
            else
              client.write(body)
            end
          rescue Errno::EPIPE, Errno::ECONNRESET
          ensure
            client.close
          end
        end
      end
    end
  end

  def base = "http://127.0.0.1:#{@server.addr[1]}"

  def close
    @thread.kill.join
    @connections.each { |thread| thread.kill.join }
    @server.close
  end

  private

  def response(path, params)
    if path == "/api/v1/categories/#{@category.fetch('id')}"
      page = params.fetch("page").to_i
      scanning = params["limit"] == "500"
      sleep 0.005 while scanning && @hold_scan_page == page
      return ["unavailable", "503 Unavailable"] if scanning && @scan_error

      books = @books.select { |book| book.fetch("title").include?(params.fetch("q", "")) }
      limit = scanning ? 6 : 12
      data = @category.merge("books" => books.slice((page - 1) * limit, limit).to_a.map { |book| book.reject { |key, _| key == "files" } },
        "pagination" => { "count" => books.length, "current_page" => page, "total_pages" => books.length.fdiv(limit).ceil,
          "next_page" => page * limit < books.length ? page + 1 : nil })
    elsif path.start_with?("/api/v1/books/")
      data = @books.find { |book| book.fetch("id") == path.split("/").last.to_i }
    elsif path.start_with?("/api/v1/files/")
      id = path.split("/").last.to_i
      data = { "pages" => (1..2).map { |number| { "id" => id * 10 + number, "number" => number, "content" => "العلم نور وأصول الفقه سبيل الفهم. نص محفوظ للقراءة والبحث دون اتصال." } },
        "pagination" => { "next_page" => nil } }
    elsif path.start_with?("/pdf/")
      return ["unavailable", "503 Unavailable"] if @failed_files.include?(path.split("/").last.to_i)

      return [@pdf, "200 OK"]
    else
      return ["missing", "404 Not Found"]
    end
    [JSON.generate(data), "200 OK"]
  end
end
