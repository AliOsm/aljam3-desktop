# frozen_string_literal: true

require "json"
require_relative "../test/support/interaction_verification"
load File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app/app.rb")
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    report = InteractionVerification.new(app, automation, output:).call
    raise "Window name does not match the OS language" unless app.style[:title] == Aljam3::Language.app_name

    if RUBY_PLATFORM.include?("darwin")
      %w[ar en].each do |language|
        strings = File.read(File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "#{language}.lproj/InfoPlist.strings"))
        raise "Missing #{language} app display name" unless strings.include?(Aljam3::Language.app_name(language))
      end
    end
    report[:app_name] = app.style[:title]
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(report))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
