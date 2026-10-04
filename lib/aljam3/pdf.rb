# frozen_string_literal: true

require "ffi"
require "chunky_png"
require "digest"
require "fileutils"
require_relative "remote_pdf"

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
    attach_function :load_custom_document, :FPDF_LoadCustomDocument, [:pointer, :string], :pointer
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

    callback :read_block, [:pointer, :ulong, :pointer, :ulong], :int

    class FileAccess < FFI::Struct
      layout :length, :ulong, :read, PDFium.find_type(:read_block), :parameter, :pointer

      def initialize(source, check:)
        super()
        self[:length] = source.size
        @read = proc do |_parameter, offset, buffer, length|
          next 0 if @error

          buffer.put_bytes(0, source.read(offset, length, check:))
          1
        rescue StandardError => error
          @error = error
          0
        end
        self[:read] = @read
      end

      # Never let a Ruby exception unwind through PDFium's C stack.
      def check!
        raise @error if @error
      end
    end

    LOCK = Mutex.new
    ANNOTATIONS = 0x01
    RGBA = 0x10
    initialize_library
  end

  class PDF
    Image = Data.define(:path, :width, :height)
    class Cancelled < StandardError; end

    def initialize(cache:)
      @cache = cache
      FileUtils.mkdir_p(cache)
    end

    def clear_cache
      PDFium::LOCK.synchronize do
        Dir.glob(File.join(@cache, "*.png{,.tmp}")).sum do |path|
          bytes = File.size(path)
          File.unlink(path)
          bytes
        rescue Errno::ENOENT
          0
        end
      end
    end

    def render(source, page:, width:, check: -> {})
      check.call
      width = Integer(width).clamp(240, 2400)
      identity = source.is_a?(RemotePDF) ? source.cache_key : "#{source}:#{File.size(source)}:#{File.mtime(source).to_f}"
      key = Digest::SHA256.hexdigest("#{identity}:#{page}:#{width}")
      target = File.join(@cache, "#{key}.png")
      PDFium::LOCK.synchronize do
        cached = cached_image(target)
        return cached if cached
        access = PDFium::FileAccess.new(source, check:) if source.is_a?(RemotePDF)
        document = access ? PDFium.load_custom_document(access, nil) : PDFium.load_document(source, nil)
        access&.check!
        raise "Unable to open this PDF." if document.null?

        count = PDFium.page_count(document)
        raise ArgumentError, "Page #{page} is outside this PDF (#{count} pages)." unless (1..count).cover?(page)

        pdf_page = PDFium.load_page(document, page - 1)
        access&.check!
        raise "Unable to read this PDF page." if pdf_page.null?

        height = (width * PDFium.page_height(pdf_page) / PDFium.page_width(pdf_page)).ceil
        raise "This PDF page is too large to display." unless height.positive? && width * height <= 16_000_000

        bitmap = PDFium.create_bitmap(width, height, 1)
        raise "Unable to allocate the PDF page image." if bitmap.null?

        PDFium.fill_bitmap(bitmap, 0, 0, width, height, 0xffffffff)
        PDFium.render(bitmap, pdf_page, 0, 0, width, height, 0, PDFium::ANNOTATIONS | PDFium::RGBA)
        access&.check!
        check.call
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

    private

    def cached_image(path)
      return unless File.file?(path)

      stream = ChunkyPNG::Datastream.from_file(path)
      header = stream.header_chunk
      unless header && header.width.positive? && header.height.positive? && stream.data_chunks.any?
        raise ChunkyPNG::ExpectationFailed, "Incomplete cached image."
      end

      now = Time.now
      File.utime(now, now, path)
      Image.new(path, header.width, header.height)
    rescue ChunkyPNG::Exception
      File.unlink(path)
      nil
    end
  end
end
