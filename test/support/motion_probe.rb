# frozen_string_literal: true

require "json"
require_relative "motion_verification"
load File.expand_path("../../app.rb", __dir__)
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report = MotionVerification.new(app, automation, output:).call
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
