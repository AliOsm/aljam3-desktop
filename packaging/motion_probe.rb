# frozen_string_literal: true

raise "Ghost checks require native CI" unless ENV["GITHUB_ACTIONS"] == "true"
ENV.delete("SCARPE_NATIVE_HEADLESS")
ENV["SCARPE_NATIVE_GHOST"] = "1"
ENV["SCARPE_NATIVE_STATS"] = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
if (activity = ENV["ALJAM3_MOTION_ACTIVITY"])
  # The app's shell launcher strips DYLD_* on macOS. Load this test-only helper
  # here for Ruby, then pass it directly to the native child before it starts.
  require "fiddle"
  MOTION_ACTIVITY = Fiddle.dlopen(activity)
  ENV["DYLD_INSERT_LIBRARIES"] = activity
end
require "json"
require_relative "../test/support/motion_benchmark"
require_relative "../test/support/continuous_reader_verification"
load File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app/app.rb")
# The renderer has started. Keep the helper out of workers and system tools.
ENV.delete("DYLD_INSERT_LIBRARIES") if activity
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    continuous = ContinuousReaderVerification.new(app, automation, output:).call
    report = MotionBenchmark.new(app, automation, output:).call(pdf: File.join(Aljam3.data_directory, "books/1/1.pdf"))
    report[:continuous] = continuous
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
