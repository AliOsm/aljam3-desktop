# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/pdf"
require_relative "support/range_pdf"

class PDFPipelineTest < Minitest::Test
  def test_memory_pixels_match_png_and_share_one_open_document
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.pdf")
      File.binwrite(path, RangePDF.image_document(pages: 3))
      pdf = Aljam3::PDF.new(cache: File.join(directory, "renders"))
      original = Aljam3::PDFium.method(:load_document)
      opened = 0
      images = Aljam3::PDFium.stub(:load_document, ->(*args) { opened += 1; original.call(*args) }) do
        [1, 3, 2, 1].map { |page| pdf.render_bitmap(path, page:, width: 240) }
      end
      assert_equal 1, opened
      assert_empty Dir.children(File.join(directory, "renders")), "Reading must not encode or write page images"
      assert_equal images.first.pixels, images.last.pixels
      refute_equal images.first.pixels, images[1].pixels
      assert images.first.pixels.frozen?
      export = File.join(directory, "export.png")
      pdf.save_bitmap(images.first, export)
      assert_equal images.first.pixels, ChunkyPNG::Image.from_file(export).to_rgba_stream
      assert_equal [240, 320], [images.first.width, images.first.height]
    ensure
      pdf&.close
    end
  end

  def test_replaced_local_document_cannot_reuse_the_previous_parser
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.pdf")
      File.binwrite(path, RangePDF.image_document(pages: 1))
      pdf = Aljam3::PDF.new(cache: File.join(directory, "renders"))
      first = pdf.render_bitmap(path, page: 1, width: 240)
      pdf.close # A downloaded file is replaced only after closing its native handle.
      File.binwrite(path, RangePDF.document(pages: 2))
      second = pdf.render_bitmap(path, page: 1, width: 240)
      refute_equal first.path, second.path
      refute_equal first.pixels, second.pixels
    ensure
      pdf&.close
    end
  end

  def test_cancelled_memory_render_does_not_poison_reused_document
    data = RangePDF.image_document(pages: 3)
    Dir.mktmpdir do |directory|
      RangePDF.serve(data) do |url, _requests|
        source = Aljam3::RemotePDF.new(url)
        pdf = Aljam3::PDF.new(cache: directory)
        first = pdf.render_bitmap(source, page: 1, width: 240)
        reads = 0
        assert_raises(Aljam3::PDF::Cancelled) do
          pdf.render_bitmap(source, page: 3, width: 240, check: -> { reads += 1; raise Aljam3::PDF::Cancelled if reads > 4 })
        end
        assert_equal first.pixels, pdf.render_bitmap(source, page: 1, width: 240).pixels
        assert_empty Dir.children(directory)
      ensure
        pdf&.close
      end
    end
  end
end
