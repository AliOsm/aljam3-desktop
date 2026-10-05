# frozen_string_literal: true

require "json"
require "digest"
require "tmpdir"
require_relative "../test/support/pdf_read_failure_verification"
require_relative "../test/support/pdf_navigation_verification"
require_relative "../test/support/continuous_reader_verification"
require_relative "../test/support/pdf_scroll_verification"

root = ENV.fetch("ALJAM3_BUNDLE_ROOT")
output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
require File.join(root, "app/lib/aljam3/pdf")
library = Aljam3::PDFium.ffi_libraries.first.name
raise "PDFium was loaded outside the bundle" unless File.realpath(library).start_with?(File.realpath(root) + File::SEPARATOR)
source = File.expand_path("..", __dir__)
patches = Dir.glob(File.join(source, "packaging/pdfium/*.patch")).sort
fingerprint = Digest::SHA256.hexdigest(File.binread(File.join(source, "bin/build-pdfium")) + patches.map { |path| File.binread(path) }.join)[0, 16]
version = File.read(File.join(root, "app/vendor/pdfium/VERSION")).strip
raise "Bundled PDFium is missing the current patches" unless version.end_with?("-#{fingerprint}")
report = { passed: true, ruby: RUBY_VERSION, platform: RUBY_PLATFORM,
  build: JSON.parse(File.read(File.join(root, "build.json"))),
  pdfium: { version:, library:, sha256: Digest::SHA256.file(library).hexdigest,
    patches: patches.to_h { |path| [File.basename(path), Digest::SHA256.file(path).hexdigest] } } }
report[:macos] = IO.popen(["/usr/bin/sw_vers"], &:read).strip if RUBY_PLATFORM.include?("darwin")
report[:failures] = [Aljam3::PDF::Cancelled, Aljam3::ConnectionError].map do |error|
  Dir.mktmpdir("aljam3-read-failure-") { |directory| PDFReadFailureVerification.call(error, directory:) }
end
load File.join(root, "app/app.rb")
app = Shoes.APPS.first
app.timer(0.5) do
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report[:navigation] = PDFNavigationVerification.new(app, automation).call
    report[:continuous] = ContinuousReaderVerification.new(app, automation, output:).call
    report[:scrolling] = PDFScrollVerification.new(app, automation, output:).call(sample: ENV["ALJAM3_BENCHMARK_PDF"])
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
