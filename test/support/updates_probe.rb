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
    supported = true
    updater.define_singleton_method(:supported?) { supported }
    app.instance_variable_get(:@store).save_preference("update_checked_at", Time.now.to_i)
    app.instance_variable_set(:@update_package, { "version" => "0.0.2" })
    checks = 0
    verify_dialog = lambda do |state|
      automation.wait_frames
      panel = automation.rect_of!(app.instance_variable_get(:@dialog_panel).linkable_id)
      raise "Update dialog outside window in #{state}" unless panel.x >= 16 && panel.x + panel.w <= app.width - 16 &&
        panel.y >= 16 && panel.y + panel.h <= app.height - 16

      body = app.instance_variable_get(:@dialog_transition).current.contents.last
      ids = body.contents.map(&:linkable_id)
      nodes = automation.layout.select { |item| ids.include?(item[:id]) }
      raise "Missing update content in #{state}" unless nodes.size == ids.size
      buttons = nodes.select { |item| item[:kind] == "Button" }
      expected = supported && %i[idle ready error current].include?(state) ? 1 : 0
      raise "Wrong update actions in #{state}" unless buttons.size == expected
      nodes.each do |item|
        raise "Update content outside dialog in #{state}" unless item[:x] >= panel.x + 16 && item[:x] + item[:w] <= panel.x + panel.w - 16 &&
          item[:y] >= panel.y + 64 && item[:y] + item[:h] <= panel.y + panel.h - 16
      end
      nodes.sort_by { |item| item[:y] }.each_cons(2) do |first, second|
        gap = second[:y] - first[:y] - first[:h]
        raise "Uneven update spacing in #{state}: #{gap}" unless gap.between?(4, 24)
      end
      bottom = nodes.map { |item| item[:y] + item[:h] }.max
      padding = panel.y + panel.h - bottom
      raise "Excess update bottom padding in #{state}: #{padding}" unless padding.between?(16, 24)
      checks += 1
      panel
    end
    %i[light dark].each do |theme|
      app.instance_variable_set(:@theme, theme)
      app.apply_theme
      [800, 1160].each do |width|
        automation.resize(width, 600)
        app.draw_window
        button = app.instance_variable_get(:@action_views).fetch(:app_updates)
        rect = automation.rect_of!(button.linkable_id)
        raise "Update icon outside window" unless rect.x >= 0 && rect.x + rect.w <= width
        %i[idle restoring checking downloading ready ready_export installing error current unsupported].each do |scenario|
          supported = scenario != :unsupported
          state = { ready_export: :ready, unsupported: :idle }.fetch(scenario, scenario)
          app.instance_variable_set(:@update_state, state)
          app.instance_variable_set(:@update_wait_for_export, scenario == :ready_export)
          app.open_dialog(:updates)
          verify_dialog.call(state)
          automation.snapshot(File.join(output, "#{theme}-#{width}-#{scenario}.png"), scale: 1)
          app.close_dialog
        end
        supported = true
        app.instance_variable_set(:@update_wait_for_export, false)
        [true, false].each do |reduced|
          MotionPreference.set(app, reduced:)
          app.instance_variable_set(:@update_state, :checking)
          app.open_dialog(:updates)
          automation.advance(0.25)
          anchor = verify_dialog.call(:checking)
          %i[downloading ready installing error checking current].each do |state|
            app.instance_variable_set(:@update_state, state)
            app.refresh_update_dialog
            panel = verify_dialog.call(state)
            raise "Update refresh moved the dialog" unless panel.x == anchor.x && panel.y == anchor.y
          end
          app.close_dialog
          automation.advance(0.15)
        end
        MotionPreference.set(app, reduced: true)
      end
    end
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(passed: true, states_checked: checks))
    # Exercise closing from a worker callback inside UI#tick, as a real update does.
    updater.define_singleton_method(:install) { |_package| true }
    app.instance_variable_set(:@update_state, :ready)
    app.restart_for_update
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
