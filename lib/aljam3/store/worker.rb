# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

module Aljam3
  class Store
    # sqlite3_step holds Ruby's VM lock. A separate process keeps expensive SQL
    # from freezing the UI, and can be stopped without interrupting a UI read.
    class Worker
      class Cancelled < StandardError; end
      METHODS = %w[search prepare_download add_pages discard_download].freeze

      def initialize(path)
        @path, @lock, @state = path, Mutex.new, Mutex.new
      end

      def call(method, *arguments, **options)
        @lock.synchronize do
          streams = @state.synchronize do
            raise Cancelled, "The library worker is closed." if @closed
            @streams ||= start
          end
          received = false
          input, output = streams
          begin
            input.puts(JSON.generate(method:, arguments:, options:))
            line = output.gets
            unless line
              cancelled = @state.synchronize { !@streams.equal?(streams) }
              raise Cancelled, "The library operation was cancelled." if cancelled
              raise "The library worker stopped unexpectedly."
            end
            response = JSON.parse(line)
            received = true
            raise response.fetch("error") if response["error"]

            response.fetch("result")
          rescue IOError, Errno::EPIPE
            raise Cancelled, "The library operation was cancelled."
          ensure
            @state.synchronize { stop if @streams.equal?(streams) } unless received
          end
        end
      end

      def cancel = @state.synchronize { stop }
      def close = @state.synchronize { @closed = true; stop }

      private

      def start
        ruby = if (bundle = ENV["ALJAM3_BUNDLE_ROOT"])
          File.join(bundle, "ruby/bin.real", Gem.win_platform? ? "rubyw.exe" : "ruby")
        else
          Gem.win_platform? ? RbConfig.ruby.sub(/ruby\.exe\z/i, "rubyw.exe") : RbConfig.ruby
        end
        # Portable Ruby launchers reset GEM_HOME/GEM_PATH. Pass the resolved
        # paths as arguments so the worker uses exactly the app's gem locations.
        Open3.popen2({ "RUBYOPT" => nil }, [ruby, ruby], File.join(__dir__, "worker_main.rb"), @path, Gem.dir, *Gem.path).tap do |input, output, _process|
          input.set_encoding(Encoding::UTF_8)
          output.set_encoding(Encoding::UTF_8)
        end
      end

      def stop
        return unless @streams

        input, output, process = @streams
        @streams = nil
        begin
          Process.kill("KILL", process.pid) if process.alive?
        rescue Errno::ESRCH
          # The child finished between alive? and kill.
        ensure
          input.close unless input.closed?
          output.close unless output.closed?
          process.join
        end
      end
    end
  end
end
