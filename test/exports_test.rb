# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/exports"
require_relative "../lib/aljam3/pdf"
require_relative "support/range_pdf"

class ExportsTest < StoreTestCase
  class View
    include Aljam3::UI::Exports
    attr_accessor :answer
    attr_reader :options

    def initialize(store, book)
      @store, @reader = store, { book: }
      @file_operations = {}
    end

    def prepare_export(file, downloader:)
      @reader[:files] = [file]
      @downloader = downloader
    end

    def save_file(_key, path:, book_id:, worker: nil, &work) = work.call

    def ask_save_file(**options)
      @options = options
      @answer
    end
  end

  def test_every_format_has_an_arabic_suggestion_and_native_type_constraint
    view = View.new(@store, book)
    %w[pdf txt docx png zip].each do |format|
      view.answer = File.join(@directory, "كتاب.#{format.upcase}")
      assert_equal view.answer, view.export_destination(format)
      assert_equal "آداب العلم 1.#{format}", view.options.fetch(:filename)
      assert_equal [format], view.options.fetch(:extensions)
      assert view.options.fetch(:expanded)
      assert_equal @directory, @store.preference("export_directory")
    end
    assert_equal @directory, view.options.fetch(:directory)
  end

  def test_cancellation_does_not_change_the_remembered_directory
    view = View.new(@store, book)
    @store.save_preference("export_directory", @directory)
    [nil, ""].each do |answer|
      view.answer = answer
      assert_nil view.export_destination("pdf")
      assert_equal @directory, @store.preference("export_directory")
    end
  end

  def test_downloaded_pdf_can_be_exported_without_a_network_connection
    file = { "id" => 10, "urls" => { "pdf" => "https://example.test/book.pdf" } }
    source = File.join(@directory, "downloaded.pdf")
    File.binwrite(source, "%PDF-1.7\nlocal book")
    downloader = Minitest::Mock.new
    downloader.expect(:pdf_path, source, [book.fetch("id"), file.fetch("id")])
    view = View.new(@store, book)
    view.prepare_export(file, downloader:)
    view.answer = File.join(@directory, "export.pdf")
    offline = Object.new
    def offline.download(*) = raise Aljam3::ConnectionError, "No network"

    Aljam3::HTTP.stub(:new, offline) { view.export_file(file, "pdf") }

    assert_equal File.binread(source), File.binread(view.answer)
    downloader.verify
  end

  def test_uncached_pdf_and_other_formats_use_their_download_urls
    urls = %w[pdf txt docx].to_h { |format| [format, "https://example.test/book.#{format}"] }
    file = { "id" => 10, "urls" => urls }
    downloader = Minitest::Mock.new
    downloader.expect(:pdf_path, File.join(@directory, "missing.pdf"), [book.fetch("id"), file.fetch("id")])
    view = View.new(@store, book)
    view.prepare_export(file, downloader:)
    http = Minitest::Mock.new
    urls.each do |format, url|
      view.answer = File.join(@directory, "export.#{format}")
      http.expect(:download, view.answer, [url, view.answer], validate_pdf: format == "pdf")
      Aljam3::HTTP.stub(:new, http) { view.export_file(file, format) }
    end
    http.verify
    downloader.verify
  end

  def test_failed_local_export_preserves_an_existing_destination
    file = { "id" => 10, "urls" => { "pdf" => "https://example.test/book.pdf" } }
    source = File.join(@directory, "downloaded.pdf")
    File.binwrite(source, "%PDF-1.7\nlocal book")
    downloader = Minitest::Mock.new
    downloader.expect(:pdf_path, source, [book.fetch("id"), file.fetch("id")])
    view = View.new(@store, book)
    view.prepare_export(file, downloader:)
    view.answer = File.join(@directory, "export.pdf")
    File.binwrite(view.answer, "previous export")
    copy = ->(_source, destination, *) do
      destination.write("partial")
      raise Errno::ENOSPC
    end
    IO.stub(:copy_stream, copy) do
      assert_raises(Errno::ENOSPC) { view.export_file(file, "pdf") }
    end
    assert_equal "previous export", File.binread(view.answer)
    assert_equal "%PDF-1.7\nlocal book", File.binread(source)
    assert_empty Dir.glob(File.join(@directory, ".aljam3-export-*"))
    downloader.expect(:pdf_path, source, [book.fetch("id"), file.fetch("id")])
    view.export_file(file, "pdf")
    assert_equal File.binread(source), File.binread(view.answer)
    assert_empty Dir.glob(File.join(@directory, ".aljam3-export-*"))
    downloader.verify
  end

  def test_safe_names_keep_arabic_and_identify_volume_and_page
    assert_equal "كتاب - الثاني - صفحة 4.png", Aljam3::ExportName.build("كتاب", "png", part: "الثاني", page: 4)
    assert_equal "كتاب.pdf", Aljam3::ExportName.build("كتاب.PDF", "pdf")
    assert_equal "كتاب جديد.txt", Aljam3::ExportName.build("كتاب:/جديد? ", "txt")
    assert_equal "الجامع.docx", Aljam3::ExportName.build("...", "docx")
    name = Aljam3::ExportName.build("آدابُ العلم " * 100, "docx")
    assert name.valid_encoding?
    assert_operator name.bytesize, :<=, 255
    File.write(File.join(@directory, name), "export")
    assert_equal ".docx", File.extname(name)
  end

  def test_long_titles_preserve_volume_and_page_identifiers
    title = "الكوكب المنير تهذيب الجامع الصغير " * 10
    first = Aljam3::ExportName.build(title, "pdf", part: "المجلد الأول")
    second = Aljam3::ExportName.build(title, "pdf", part: "المجلد الثاني")
    refute_equal first, second
    assert first.end_with?(" - المجلد الأول.pdf")
    assert second.end_with?(" - المجلد الثاني.pdf")
    page = Aljam3::ExportName.build(title, "png", page: 104)
    assert page.end_with?(" - صفحة 104.png")
    [first, second, page].each do |name|
      assert name.valid_encoding?
      assert_operator name.bytesize, :<=, 255
    end
  end

  def test_suggested_names_do_not_use_reserved_windows_devices
    %w[CON NUL AUX PRN COM1 LPT9 CONIN$ CONOUT$].each do |title|
      name = Aljam3::ExportName.build(title, "pdf")
      refute_equal "#{title}.pdf", name
      assert name.end_with?(".pdf")
    end
  end

  def test_page_image_export_recovers_its_original_page_after_cache_eviction_and_navigation
    source = File.join(@directory, "book.pdf")
    File.binwrite(source, RangePDF.document(pages: 2))
    pdf = Aljam3::PDF.new(cache: File.join(@directory, "renders"))
    rendered = pdf.render_bitmap(source, page: 1, width: 240)
    expected = rendered.pixels
    reading = Minitest::Mock.new
    view = View.new(@store, book)
    view.instance_variable_set(:@pdf, pdf)
    view.instance_variable_set(:@reading, reading)
    reader = view.instance_variable_get(:@reader)
    reader.merge!(file: book.fetch("files").first, number: 1, image: rendered)
    view.answer = File.join(@directory, "page.png")
    work = nil
    view.define_singleton_method(:save_file) { |_key, **_options, &operation| work = operation }

    view.save_page_image
    pdf.clear_cache
    reader.merge!(book: book(2), file: book(2).fetch("files").first, number: 2, image: nil)
    File.binwrite(view.answer, "previous image")
    pdf.stub(:save_bitmap, ->(*) { raise Errno::ENOSPC }) do
      assert_raises(Errno::ENOSPC) { work.call }
    end
    assert_equal "previous image", File.binread(view.answer)
    pdf.clear_cache
    work.call

    assert_equal expected, ChunkyPNG::Image.from_file(view.answer).to_rgba_stream
    reading.verify
  ensure
    pdf&.close
  end
end
