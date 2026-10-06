# frozen_string_literal: true

require "tmpdir"
require "zip"
require_relative "http"
require_relative "export_name"
require_relative "formatting"
require_relative "text"

module Aljam3
  class ArchiveExport
    class Cancelled < StandardError; end

    class Stream < Zip::OutputStream
      def close
        super
      ensure
        # A failed ZIP footer write must still release the file for Windows cleanup.
        @output_stream.close unless @output_stream.closed?
        @closed = true
      end
    end
    private_constant :Stream

    attr_reader :format

    def initialize(book:, files:, format:, downloader:, http: HTTP.new)
      raise ArgumentError, "Unknown export format." unless %w[pdf txt docx].include?(format)
      raise ArgumentError, "No files to export." if files.empty?

      @book, @files, @format, @downloader, @http = book, files, format, downloader, http
    end

    def cancel = @cancelled = true
    def cancelled? = !!@cancelled
    def reset = @cancelled = false

    def available?
      @files.all? { |file| local_source(file) || !file.dig("urls", @format).to_s.empty? }
    end

    def call(destination, &progress)
      check
      raise ArgumentError, "This format is not available for every volume." unless available?

      @last_progress = nil
      # Stage beside the destination so the completed archive replaces it atomically.
      # Only one downloaded volume and bounded chunks of its contents are held at a time.
      Dir.mktmpdir(".aljam3-export-", File.dirname(destination)) do |directory|
        archive = File.join(directory, "book.zip")
        Stream.open(archive) do |zip|
          @files.each_with_index do |file, index|
            check
            source = local_source(file)
            downloaded = !source
            if downloaded
              source = File.join(directory, "volume.#{@format}")
              report(index, 0, :download, &progress)
              @http.download(file.fetch("urls").fetch(@format), source, validate_pdf: @format == "pdf", check: method(:check)) do |bytes, total|
                fraction = total && total.positive? ? (bytes.fdiv(total) * 0.8).clamp(0, 0.8) : 0
                report(index, fraction, :download, &progress)
              end
            end
            check
            name = entry_name(file, index)
            compression = @format == "txt" ? Zip::Entry::DEFLATED : Zip::Entry::STORED
            entry = Zip::Entry.new("", name, compression_method: compression)
            entry.gp_flags |= 0x800 # UTF-8 filenames in Windows Explorer and macOS Archive Utility.
            zip.put_next_entry(entry)
            report(index, downloaded ? 0.8 : 0, :archive, &progress)
            File.open(source, "rb") do |input|
              size = input.size
              while (chunk = input.read(1024 * 1024))
                check
                zip.write(chunk)
                fraction = input.pos.fdiv(size)
                fraction = 0.8 + fraction * 0.2 if downloaded
                report(index, fraction, :archive, &progress)
              end
            end
            File.unlink(source) if downloaded
            report(index, 1, :archive, &progress)
          end
        end
        check
        File.rename(archive, destination)
      end
      destination
    end

    private

    def check
      raise Cancelled if @cancelled
    end

    def local_source(file)
      return unless @format == "pdf"

      path = @downloader.pdf_path(@book.fetch("id"), file.fetch("id"))
      path if File.file?(path)
    end

    def entry_name(file, index)
      number = (index + 1).to_s.rjust([2, @files.length.to_s.length].max, "0")
      ExportName.build("#{number} - #{Text.plain(file.fetch('name', ''))}", @format)
    end

    def report(index, fraction, phase)
      return unless block_given?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @last_progress && @last_progress[0..1] == [index, phase] && fraction != 1 && now - @last_progress.last < 0.15

      @last_progress = [index, phase, now]
      label = phase == :download ? "تنزيل #{@format.upcase}" : "تجهيز ZIP"
      yield (index + fraction).fdiv(@files.length), "#{label} · #{Formatting.number(index + 1)} / #{Formatting.number(@files.length)}"
    end
  end
end
