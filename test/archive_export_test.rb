# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/archive_export"

class ArchiveExportTest < StoreTestCase
  class Transfer
    attr_accessor :failure, :interrupt
    attr_reader :requests

    def initialize
      @requests = []
    end

    def download(url, path, validate_pdf:, check:)
      @requests << [url, validate_pdf]
      body = self.class.body(url)
      File.open(path, "wb") do |file|
        check.call
        file.write(body)
        @interrupt&.call
        raise @failure if @failure && @requests.length == 2

        check.call
        yield body.bytesize, body.bytesize
      end
    end

    def self.body(url) = "%PDF-1.7\n#{url}\nنص عربي\n".b
  end

  def setup
    super
    @book = book
    @files = [32, 10, 21].map do |id|
      { "id" => id, "name" => "المجلد:/الأول.pdf", "urls" => %w[pdf txt docx].to_h { |format| [format, "https://example.test/#{id}.#{format}"] } }
    end
    @book["files"] = @files
    @http = Transfer.new
    @downloader = Aljam3::Downloader.new(api: nil, store: @store, directory: File.join(@directory, "library"))
    @destination = File.join(@directory, "مجموعة الكتب.zip")
  end

  def exporter(format = "pdf")
    Aljam3::ArchiveExport.new(book: @book, files: @files, format:, downloader: @downloader, http: @http)
  end

  def archive_entries
    Zip::File.open(@destination) { |zip| zip.entries.map { |entry| [entry.name.dup.force_encoding(Encoding::UTF_8), entry.get_input_stream.read] } }
  end

  def assert_no_temporary_files
    assert_empty Dir.glob(File.join(@directory, ".aljam3-export-*"))
  end

  def test_each_format_contains_every_volume_in_reading_order_with_safe_unique_unicode_names
    %w[pdf txt docx].each do |format|
      progress = []
      exporter(format).call(@destination) { |fraction, message| progress << [fraction, message] }
      entries = archive_entries
      assert_equal ["01 - المجلد الأول.#{format}", "02 - المجلد الأول.#{format}", "03 - المجلد الأول.#{format}"], entries.map(&:first)
      assert_equal @files.map { |file| Transfer.body(file.fetch("urls").fetch(format)) }, entries.map(&:last)
      assert_equal progress.map(&:first).sort, progress.map(&:first)
      assert_equal 1.0, progress.last.first
      Zip::File.open(@destination) { |zip| assert zip.entries.all? { |entry| entry.gp_flags & 0x800 != 0 } }
      assert_no_temporary_files
    end
    assert_equal [true] * 3 + [false] * 6, @http.requests.map(&:last)
  end

  def test_downloaded_pdfs_are_reused_and_only_missing_volumes_are_fetched
    source = @downloader.pdf_path(@book.fetch("id"), @files.first.fetch("id"))
    FileUtils.mkdir_p(File.dirname(source))
    File.binwrite(source, "%PDF-local volume")
    @files.first["urls"] = {}

    archive = exporter
    assert archive.available?
    archive.call(@destination)

    assert_equal "%PDF-local volume", archive_entries.first.last
    assert_equal @files.drop(1).map { |file| [file.dig("urls", "pdf"), true] }, @http.requests
    assert_equal "%PDF-local volume", File.binread(source)
    assert_no_temporary_files
  end

  def test_all_downloaded_pdfs_can_be_archived_without_urls_or_network
    @files.each do |file|
      path = @downloader.pdf_path(@book.fetch("id"), file.fetch("id"))
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "%PDF-#{file.fetch('id')}")
      file["urls"] = {}
    end
    exporter.call(@destination)
    assert_equal @files.map { |file| "%PDF-#{file.fetch('id')}" }, archive_entries.map(&:last)
    assert_empty @http.requests
  end

  def test_missing_format_never_publishes_an_incomplete_archive
    @files.last["urls"].delete("txt")
    File.write(@destination, "existing ZIP")
    archive = exporter("txt")
    refute archive.available?
    assert_raises(ArgumentError) { archive.call(@destination) }
    assert_equal "existing ZIP", File.read(@destination)
    assert_empty @http.requests
    assert_no_temporary_files
  end

  def test_failed_later_volume_preserves_destination_and_retry_produces_the_complete_archive
    [Aljam3::ConnectionError.new("interrupted"), Errno::ENOSPC.new].each do |error|
      @http = Transfer.new
      @http.failure = error
      File.write(@destination, "previous ZIP")
      archive = exporter
      assert_raises(error.class) { archive.call(@destination) }
      assert_equal "previous ZIP", File.read(@destination)
      assert_no_temporary_files

      @http.failure = nil
      archive.call(@destination)
      assert_equal 3, archive_entries.size
      assert_no_temporary_files
    end
  end

  def test_cancellation_during_download_cleans_up_and_can_restart
    archive = exporter
    File.write(@destination, "previous ZIP")
    @http.interrupt = -> { archive.cancel }
    assert_raises(Aljam3::ArchiveExport::Cancelled) { archive.call(@destination) }
    assert_equal "previous ZIP", File.read(@destination)
    assert_no_temporary_files
    @http.interrupt = nil
    archive.reset
    archive.call(@destination)
    assert_equal 3, archive_entries.size
  end

  def test_disk_failure_finalizing_zip_closes_its_handle_and_preserves_the_previous_file
    File.write(@destination, "previous ZIP")
    create_file = File.method(:new)
    handle = nil
    fail_footer = ->(*args, **options) do
      file = create_file.call(*args, **options)
      if args.first.to_s.end_with?("/book.zip")
        handle = file
        write = file.method(:write)
        file.define_singleton_method(:write) do |bytes|
          raise Errno::ENOSPC if bytes.start_with?("PK\x01\x02")

          write.call(bytes)
        end
      end
      file
    end
    File.stub(:new, fail_footer) { assert_raises(Errno::ENOSPC) { exporter.call(@destination) } }
    assert handle.closed?
    assert_equal "previous ZIP", File.read(@destination)
    assert_no_temporary_files
    exporter.call(@destination)
    assert_equal 3, archive_entries.size
  end

  def test_cancellation_while_archiving_and_before_a_queued_job_starts
    archive = exporter
    assert_raises(Aljam3::ArchiveExport::Cancelled) do
      archive.call(@destination) { |_fraction, message| archive.cancel if message.start_with?("تجهيز ZIP") }
    end
    refute File.exist?(@destination)
    assert_no_temporary_files
    @http.requests.clear
    assert_raises(Aljam3::ArchiveExport::Cancelled) { archive.call(@destination) }
    assert_empty @http.requests
    assert_no_temporary_files
  end

  def test_long_and_path_like_volume_names_stay_within_portable_filename_limits
    @files.each { |file| file["name"] = "../<mark>كتاب</mark>\\" + "نص طويل " * 100 }
    exporter.call(@destination)
    names = archive_entries.map(&:first)
    assert_equal names.length, names.uniq.length
    names.each do |name|
      assert name.valid_encoding?
      assert_operator name.bytesize, :<=, 255
      refute_match(/[<>:\\\/|?*\x00-\x1f]/, name)
    end
  end
end
