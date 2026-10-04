# frozen_string_literal: true

require_relative "range_pdf"

# Shared by the isolated regression tests and the actual bundled runtime.
# The caller loads its own production PDF code; never load the checkout here.
module PDFReadFailureVerification
  def self.call(error_class, directory:)
    data = RangePDF.image_document
    path = File.join(directory, "book.pdf")
    File.binwrite(path, data)
    cache = File.join(directory, "renders")
    pdf = Aljam3::PDF.new(cache:)

    RangePDF.serve(data) do |url, _requests|
      http = Aljam3::HTTP.new
      fail_read = error_class == Aljam3::ConnectionError
      http.define_singleton_method(:read_range) do |*args, **options|
        if fail_read && options.fetch(:offset) == Aljam3::RemotePDF::BLOCK_SIZE
          raise Aljam3::ConnectionError, "Interrupted PDF image read"
        end
        super(*args, **options)
      end

      source = Aljam3::RemotePDF.new(url, http:)
      reading_image = false
      image_reads = 0
      source.define_singleton_method(:read) do |offset, length, check:|
        reading_image = length > Aljam3::RemotePDF::BLOCK_SIZE
        image_reads += 1 if reading_image
        super(offset, length, check:)
      ensure
        reading_image = false
      end
      image_checks = 0
      check = -> {
        if reading_image
          image_checks += 1
          if error_class == Aljam3::PDF::Cancelled && image_checks == 2
            raise Aljam3::PDF::Cancelled, "Navigated away during PDF image read"
          end
        end
      }

      begin
        pdf.render(source, page: 1, width: 240, check:)
        raise "Expected #{error_class} during the image read"
      rescue error_class => error
        expected = error_class == Aljam3::PDF::Cancelled ? "Navigated away during PDF image read" : "Interrupted PDF image read"
        raise "Original callback error was lost" unless error.message == expected
      end
      raise "Failure must occur inside the image stream read" unless image_reads.positive?
      raise "Failed renders must not be cached" unless Dir.glob(File.join(cache, "*")).empty?

      fail_read = false
      rendered = pdf.render(source, page: 1, width: 240)
      reference = pdf.render(path, page: 1, width: 240)
      raise "Retry pixels differ from the local PDF" unless File.binread(reference.path) == File.binread(rendered.path)

      { error: error_class.name, image_reads:, original_error: true, failed_cache_empty: true, retry_pixels_match: true }
    ensure
      http&.close
    end
  end
end
