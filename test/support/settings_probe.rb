# frozen_string_literal: true

require "json"
require_relative "settings_verification"
require_relative "../../packaging/verify_theme"
app_root = ENV["ALJAM3_BUNDLE_ROOT"] ? File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app") : File.expand_path("../..", __dir__)
require File.join(app_root, "lib/aljam3")
store = Aljam3::Store.new(File.join(Aljam3.data_directory, "library.sqlite3"))
store.save_preference("theme", "dark")
store.close
ThemeVerification.call(output: ENV.fetch("ALJAM3_VERIFY_OUTPUT"), system_reads: 0) { load File.join(app_root, "app.rb") }
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
