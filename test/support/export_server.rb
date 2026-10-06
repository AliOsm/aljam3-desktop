# frozen_string_literal: true

require "socket"

# Real HTTP transfers with deterministic interruption and progress points.
class ExportServer
  attr_accessor :fail_path, :hold_path
  attr_reader :requests, :waiting, :release

  def initialize(bodies)
    @requests, @waiting, @release = [], Queue.new, Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @base = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new do
      loop do
        socket = @server.accept
        begin
          path = socket.gets.split[1]
          while (header = socket.gets) && header != "\r\n"; end
          @requests << path
          body = bodies.fetch(path).b
          status = path == @fail_path ? "503 Unavailable" : "200 OK"
          socket.write("HTTP/1.1 #{status}\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
          split = [body.bytesize / 2, 65_536].min
          socket.write(body.byteslice(0, split))
          if path == @hold_path
            @waiting << path
            @release.pop
          end
          socket.write(body.byteslice(split..))
        rescue Errno::EPIPE, Errno::ECONNRESET
          # Cancellation can close the connection before the remaining bytes arrive.
        ensure
          socket.close
        end
      end
    end
  end

  def url(path) = "#{@base}#{path}"

  def close
    @thread.kill.join
    @server.close
  end
end
