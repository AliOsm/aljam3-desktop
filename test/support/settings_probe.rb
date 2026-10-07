# frozen_string_literal: true

require "json"
require_relative "settings_verification"
app_path = ENV["ALJAM3_BUNDLE_ROOT"] ? File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app/app.rb") : File.expand_path("../../app.rb", __dir__)
load app_path
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report = SettingsVerification.new(app, automation, output:).call
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    automation&.snapshot(File.join(output, "failed.png"), scale: 1)
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
