# frozen_string_literal: true

raise "Ghost checks require native CI" unless ENV["GITHUB_ACTIONS"] == "true"
ENV.delete("SCARPE_NATIVE_HEADLESS")
ENV["SCARPE_NATIVE_GHOST"] = "1"
ENV["SCARPE_NATIVE_STATS"] = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
require "json"
require_relative "../test/support/motion_benchmark"
load File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app/app.rb")
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report = MotionBenchmark.new(app, automation, output:).call(pdf: File.join(Aljam3.data_directory, "books/1/1.pdf"))
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
