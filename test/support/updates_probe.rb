# frozen_string_literal: true

require "json"
require_relative "motion_preference"
load File.expand_path("../../app.rb", __dir__)
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    MotionPreference.set(app, reduced: true)
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    updater = app.instance_variable_get(:@updater)
    updater.define_singleton_method(:supported?) { true }
    app.instance_variable_get(:@store).save_preference("update_checked_at", Time.now.to_i)
    app.instance_variable_set(:@update_package, { "version" => "0.0.2" })
    checks = 0
    %i[light dark].each do |theme|
      app.instance_variable_set(:@theme, theme)
      app.apply_theme
      [800, 1160].each do |width|
        automation.resize(width, 600)
        app.draw_window
        button = app.instance_variable_get(:@action_views).fetch(:app_updates)
        rect = automation.rect_of!(button.linkable_id)
        raise "Update icon outside window" unless rect.x >= 0 && rect.x + rect.w <= width
        %i[idle checking downloading ready installing error current].each do |state|
          app.instance_variable_set(:@update_state, state)
          app.open_dialog(:updates)
          automation.wait_frames
          panel = automation.rect_of!(app.instance_variable_get(:@dialog_panel).linkable_id)
          raise "Update dialog outside window" unless panel.y >= 0 && panel.y + panel.h <= 600
          buttons = automation.layout.select { |item| item[:kind] == "Button" && item[:text].match?(/التحقق من التحديثات|إعادة التشغيل والتحديث/) }
          expected = %i[idle ready error current].include?(state) ? 1 : 0
          raise "Wrong update actions in #{state}" unless buttons.size == expected
          buttons.each do |item|
            raise "Update action outside dialog" unless item[:y] >= panel.y && item[:y] + item[:h] <= panel.y + panel.h
          end
          automation.snapshot(File.join(output, "#{theme}-#{width}-#{state}.png"), scale: 1)
          app.close_dialog
          checks += 1
        end
      end
    end
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(passed: true, states_checked: checks))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
