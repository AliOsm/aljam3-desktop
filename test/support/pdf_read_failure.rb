# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/aljam3/pdf"
require_relative "pdf_read_failure_verification"

Process.setrlimit(Process::RLIMIT_CORE, 0, 0) if defined?(Process::RLIMIT_CORE)

class PDFReadFailureTest < Minitest::Test
  def test_cancellation
    assert PDFReadFailureVerification.call(Aljam3::PDF::Cancelled, directory: ENV.fetch("ALJAM3_PDF_FAILURE_DIR"))
  end

  def test_network_failure
    assert PDFReadFailureVerification.call(Aljam3::ConnectionError, directory: ENV.fetch("ALJAM3_PDF_FAILURE_DIR"))
  end
end
