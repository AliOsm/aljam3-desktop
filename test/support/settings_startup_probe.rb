# frozen_string_literal: true

require "json"
app_root = ENV["ALJAM3_BUNDLE_ROOT"] ? File.join(ENV.fetch("ALJAM3_BUNDLE_ROOT"), "app") : File.expand_path("../..", __dir__)
require File.join(app_root, "lib/aljam3")
require File.join(app_root, "lib/aljam3/storage")
require_relative "motion_preference"

directory = Aljam3.data_directory
path = File.join(Dir.home, "External drive", "مكتبتي")
parked = path + "-disconnected"
FileUtils.mkdir_p(directory)
store = Aljam3::Store.new(File.join(parked, "library.sqlite3"))
store.save_preference("startup-proof", "original library")
store.save_preference("update_checked_at", Time.now.to_i)
store.close
File.write(File.join(parked, Aljam3::Storage::MARKER), JSON.generate("id" => "startup-fixture"))
Aljam3::Storage.new.select(path, "startup-fixture")

load File.join(app_root, "app.rb")
app = Shoes.APPS.first
app.timer(0.5) do
  output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
  begin
    MotionPreference.set(app, reduced: true)
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    get = ->(key) { app.instance_variable_get("@#{key}") }
    checks = []
    check = ->(label, value) { raise label unless value; checks << label }
    check.call("Startup with missing drive shows recovery", get.call(:library_unavailable))
    check.call("Startup never creates a replacement database", !get.call(:store) && !File.exist?(File.join(directory, "library.sqlite3")) && !File.exist?(path))
    automation.snapshot(File.join(output, "missing-drive-startup.png"), scale: 1)
    File.rename(parked, path)
    automation.click({ id: get.call(:action_views).fetch(:retry_library).linkable_id })
    automation.wait_frames
    check.call("Retry opens original library after reconnect", !get.call(:library_unavailable) && get.call(:store).preference("startup-proof") == "original library")
    check.call("App and external library locks are held", !Aljam3::Instance.acquire(directory) && !Aljam3::Instance.acquire(path))
    automation.click({ id: get.call(:action_views).fetch(:settings).linkable_id })
    automation.snapshot(File.join(output, "reconnected-startup.png"), scale: 1)
    # Shutdown also has to work when no library services are available.
    storage = get.call(:storage)
    if Gem.win_platform?
      # Windows cannot rename open SQLite files. Signal removal first so the
      # app releases its handles, then simulate the absent drive path.
      storage.define_singleton_method(:available?) { false }
      app.instance_variable_set(:@library_checked_at, nil)
      app.tick
      storage.singleton_class.remove_method(:available?)
    end
    File.rename(path, parked)
    app.instance_variable_set(:@library_checked_at, nil)
    app.tick
    check.call("Drive removal returns to recovery before shutdown", get.call(:library_unavailable) && !get.call(:store))
    File.write(File.join(output, "passed.json"), JSON.pretty_generate(passed: true, checks:))
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
  ensure
    app.close
  end
end
