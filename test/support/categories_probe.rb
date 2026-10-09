# frozen_string_literal: true

require "json"
require_relative "categories_verification"
app_root = ENV["ALJAM3_BUNDLE_ROOT"] ? File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app") : File.expand_path("../..", __dir__)
load File.join(app_root, "app.rb")
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report = CategoriesVerification.new(app, automation, output:).call
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
