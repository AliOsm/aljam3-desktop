# frozen_string_literal: true

require "ffi"
require "chunky_png"
require "digest"
require "fileutils"

module Aljam3
  module PDFium
    extend FFI::Library
    library = if FFI::Platform.windows?
      "bin/pdfium.dll"
    else
      "lib/libpdfium.#{FFI::Platform.mac? ? 'dylib' : 'so'}"
    end
    ffi_lib File.expand_path("../../vendor/pdfium/#{library}", __dir__)

    attach_function :initialize_library, :FPDF_InitLibrary, [], :void
    attach_function :load_document, :FPDF_LoadDocument, [:string, :string], :pointer
    attach_function :close_document, :FPDF_CloseDocument, [:pointer], :void
    attach_function :page_count, :FPDF_GetPageCount, [:pointer], :int
    attach_function :load_page, :FPDF_LoadPage, [:pointer, :int], :pointer
    attach_function :close_page, :FPDF_ClosePage, [:pointer], :void
    attach_function :page_width, :FPDF_GetPageWidthF, [:pointer], :float
    attach_function :page_height, :FPDF_GetPageHeightF, [:pointer], :float
    attach_function :create_bitmap, :FPDFBitmap_Create, [:int, :int, :int], :pointer
    attach_function :fill_bitmap, :FPDFBitmap_FillRect, [:pointer, :int, :int, :int, :int, :ulong], :int
    attach_function :render, :FPDF_RenderPageBitmap, [:pointer, :pointer, :int, :int, :int, :int, :int, :int], :void, blocking: true
    attach_function :buffer, :FPDFBitmap_GetBuffer, [:pointer], :pointer
    attach_function :destroy_bitmap, :FPDFBitmap_Destroy, [:pointer], :void

    LOCK = Mutex.new
    ANNOTATIONS = 0x01
    RGBA = 0x10
    initialize_library
  end

  class PDF
    Image = Data.define(:path, :width, :height)

    def initialize(cache:)
      @cache = cache
      FileUtils.mkdir_p(cache)
    end

    def render(path, page:, width:)
      width = Integer(width).clamp(240, 2400)
      key = Digest::SHA256.hexdigest("#{path}:#{File.size(path)}:#{File.mtime(path).to_f}:#{page}:#{width}")
      target = File.join(@cache, "#{key}.png")
      PDFium::LOCK.synchronize do
        if File.file?(target)
          image = ChunkyPNG::Datastream.from_file(target).header_chunk
          return Image.new(target, image.width, image.height)
        end
        document = PDFium.load_document(path, nil)
        raise "Unable to open this PDF." if document.null?

        count = PDFium.page_count(document)
        raise ArgumentError, "Page #{page} is outside this PDF (#{count} pages)." unless (1..count).cover?(page)

        pdf_page = PDFium.load_page(document, page - 1)
        raise "Unable to read this PDF page." if pdf_page.null?

        height = (width * PDFium.page_height(pdf_page) / PDFium.page_width(pdf_page)).ceil
        raise "This PDF page is too large to display." unless height.positive? && width * height <= 16_000_000

        bitmap = PDFium.create_bitmap(width, height, 1)
        raise "Unable to allocate the PDF page image." if bitmap.null?

        PDFium.fill_bitmap(bitmap, 0, 0, width, height, 0xffffffff)
        PDFium.render(bitmap, pdf_page, 0, 0, width, height, 0, PDFium::ANNOTATIONS | PDFium::RGBA)
        pixels = PDFium.buffer(bitmap).read_string_length(width * height * 4)
        ChunkyPNG::Image.from_rgba_stream(width, height, pixels).save("#{target}.tmp", :fast_rgba)
        File.rename("#{target}.tmp", target)
        # Keep a small render cache, independently of the downloaded source PDFs.
        Dir.glob(File.join(@cache, "*.png")).sort_by { |file| File.mtime(file) }.reverse.drop(24).each { |file| File.delete(file) }
        Image.new(target, width, height)
      ensure
        PDFium.destroy_bitmap(bitmap) if bitmap && !bitmap.null?
        PDFium.close_page(pdf_page) if pdf_page && !pdf_page.null?
        PDFium.close_document(document) if document && !document.null?
      end
    end
  end
end
