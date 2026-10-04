# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/pdf"
require_relative "support/range_pdf"
require "timeout"

class PDFCacheTest < Minitest::Test
  def test_damaged_cached_images_are_regenerated_from_the_pdf
    Dir.mktmpdir do |directory|
      source = File.join(directory, "book.pdf")
      File.binwrite(source, RangePDF.image_document(pages: 1))
      pdf = Aljam3::PDF.new(cache: File.join(directory, "renders"))
      image = pdf.render(source, page: 1, width: 240)
      original = File.binread(image.path)
      damaged = original.dup
      damaged.setbyte(45, damaged.getbyte(45) ^ 1)
      ["", original.byteslice(0, 40), damaged, ChunkyPNG::Datastream::SIGNATURE + original.byteslice(-12, 12)].each do |bytes|
        File.binwrite(image.path, bytes)
        assert_equal image, pdf.render(source, page: 1, width: 240)
        assert_equal original, File.binread(image.path)
      end
    end
  end

  def test_clearing_waits_for_an_active_cached_render
    Dir.mktmpdir do |directory|
      source = File.join(directory, "book.pdf")
      File.binwrite(source, RangePDF.document(pages: 1))
      pdf = Aljam3::PDF.new(cache: File.join(directory, "renders"))
      image = pdf.render(source, page: 1, width: 240)
      entered, release = Queue.new, Queue.new
      original = ChunkyPNG::Datastream.method(:from_file)
      read = ->(*arguments) { entered << true; release.pop; original.call(*arguments) }
      ChunkyPNG::Datastream.stub(:from_file, read) do
        render = Thread.new { pdf.render(source, page: 1, width: 240) }
        Timeout.timeout(5) { entered.pop }
        clearer = Thread.new { pdf.clear_cache }
        Timeout.timeout(5) { Thread.pass until clearer.status == "sleep" || !clearer.alive? }
        assert clearer.alive?, "Cache clearing must wait for the render's file access"
        assert File.file?(image.path)
        release << true
        assert_equal image, render.value
        assert_operator clearer.value, :>, 0
      ensure
        release << true
        render&.join
        clearer&.join
      end
      refute File.exist?(image.path)
      assert File.file?(pdf.render(source, page: 1, width: 240).path)
    end
  end

  def test_clearing_removes_abandoned_temporary_images_but_keeps_other_files
    Dir.mktmpdir do |directory|
      pdf = Aljam3::PDF.new(cache: directory)
      File.binwrite(File.join(directory, "page.png"), "png")
      File.binwrite(File.join(directory, "page.png.tmp"), "partial")
      source = File.join(directory, "book.pdf")
      File.binwrite(source, "PDF")

      assert_equal 10, pdf.clear_cache
      assert_equal [source], Dir.glob(File.join(directory, "*"))
      assert_equal 0, pdf.clear_cache
    end
  end
end
