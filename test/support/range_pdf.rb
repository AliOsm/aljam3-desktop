# frozen_string_literal: true

require "socket"

module RangePDF
  # Separate page streams make accidental whole-file reads visible in byte counts.
  def self.document(pages: 24, branch_size: nil)
    objects = ["<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count #{pages} /Kids [#{pages.times.map { |i| "#{3 + i * 2} 0 R" }.join(' ')}] >>"]
    pages.times do |index|
      content = "#{(index + 1).fdiv(pages + 1)} 0.4 0.6 rg #{index % 24 * 8} 10 30 100 re f\n" + ("% padding\n" * 13_000)
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 320] /Resources << >> /Contents #{4 + index * 2} 0 R >>"
      objects << "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream"
    end
    if branch_size
      nodes = pages.times.map { |index| [3 + index * 2, 1] }
      while nodes.size > branch_size
        nodes = nodes.each_slice(branch_size).map do |children|
          parent = objects.size + 1
          children.each do |id, _count|
            objects[id - 1] = objects[id - 1].sub("/Parent 2 0 R", "/Parent #{parent} 0 R")
          end
          count = children.sum(&:last)
          objects << "<< /Type /Pages /Parent 2 0 R /Count #{count} /Kids [#{children.map { |id, _| "#{id} 0 R" }.join(' ')}] >>"
          [parent, count]
        end
      end
      objects[1] = "<< /Type /Pages /Count #{pages} /Kids [#{nodes.map { |id, _| "#{id} 0 R" }.join(' ')}] >>"
    end
    pdf = +"%PDF-1.7\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  def self.serve(pdf)
    requests = []
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = nil
      loop do
        socket = server.accept
        headers = +""
        while (line = socket.gets) && line != "\r\n"
          headers << line
        end
        range = headers.match(/^Range: bytes=(\d+)-(\d+)/i)
        raise "Reader requested the full PDF" unless range

        first, last = range.captures.map(&:to_i)
        last = [last, pdf.bytesize - 1].min
        bytes = pdf.byteslice(first..last)
        requests << [first, bytes.bytesize]
        socket.write("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes #{first}-#{last}/#{pdf.bytesize}\r\nContent-Length: #{bytes.bytesize}\r\nETag: \"v1\"\r\nConnection: close\r\n\r\n")
        socket.write(bytes)
        socket.close
      end
    ensure
      socket&.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/book.pdf", requests
  ensure
    thread&.kill&.join
    server&.close
  end
end
