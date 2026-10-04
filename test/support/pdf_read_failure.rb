# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/aljam3/pdf"
require_relative "range_pdf"

Process.setrlimit(Process::RLIMIT_CORE, 0, 0) if defined?(Process::RLIMIT_CORE)

class PDFReadFailureTest < Minitest::Test
  def test_cancellation
    verify_failure(Aljam3::PDF::Cancelled)
  end

  def test_network_failure
    verify_failure(Aljam3::ConnectionError)
  end

  private

  def verify_failure(error_class)
    directory = ENV.fetch("ALJAM3_PDF_FAILURE_DIR")
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

      assert_raises(error_class) { pdf.render(source, page: 1, width: 240, check:) }
      assert_operator image_reads, :>, 0, "Failure must occur inside the image stream read"
      assert_empty Dir.glob(File.join(cache, "*.png")), "Failed renders must not be cached"

      fail_read = false
      rendered = pdf.render(source, page: 1, width: 240)
      reference = pdf.render(path, page: 1, width: 240)
      assert_equal File.binread(reference.path), File.binread(rendered.path), "Reading must recover after cancellation or a network failure"
    ensure
      http&.close
    end
  end
end
