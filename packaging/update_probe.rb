# frozen_string_literal: true

# Runs through the installed launcher both before and after the real upgrade.
require "json"
require "digest"
root = ENV.fetch("ALJAM3_BUNDLE_ROOT")
output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
at_exit do
  File.write(File.join(output, "failed.txt"), $!.full_message) if $!.is_a?(StandardError)
end
require File.join(root, "app/lib/aljam3")
require File.join(root, "app/lib/aljam3/updates")
directory = Aljam3.data_directory
build = JSON.parse(File.read(File.join(root, "build.json")))
store = Aljam3::Store.new(File.join(directory, "library.sqlite3"))
if build.fetch("version") == "0.0.2"
  result = File.read(File.join(directory, "updates/result.txt")).strip
  raise "Updater reported #{result}" unless result == "installed"
  raise "Active download was not safely queued before shutdown" unless store.download(90_001).fetch(:status) == :queued
  raise "Paused download changed during update" unless store.download(90_002).fetch(:status) == :paused
  raise "Partial download progress lost" unless store.download(90_001).fetch(:bytes) == 40
  raise "Partial download content changed" unless File.read(File.join(directory, "transfer.part")) == "partially downloaded book"
end
store.save_preference("update_checked_at", Time.now.to_i)
store.close
load File.join(root, "app/app.rb")
app = Shoes.APPS.first
downloader = app.instance_variable_get(:@downloader)
real_download = downloader.method(:call)
downloader.define_singleton_method(:call) do |id, check:, &progress|
  next real_download.call(id, check:, &progress) unless [90_001, 90_002].include?(id)
  progress.call(0.4, "PDF", 40, 100)
  loop { check.call; sleep 0.01 }
end
phase = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
app.every(0.1) do
  begin
    raise "Update UI timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 180
    store = app.instance_variable_get(:@store)
    if build.fetch("version") == "0.0.2"
      next unless app.instance_variable_get(:@download_queue).current&.dig(:book, "id") == 90_001
      raise "Reading position lost" unless store.preference("reading:1").fetch("number") == 72
      raise "Preference lost" unless store.preference("update_sentinel") == "مكتبة الجامع"
      raise "Downloaded book lost" unless store.downloaded?(1)
      raise "Offline search lost" if store.search("العلم").fetch("pages").empty?
      before = JSON.parse(File.read(ENV.fetch("ALJAM3_UPGRADE_SENTINEL")))
      before.each { |path, digest| raise "Book content changed" unless Digest::SHA256.file(path).hexdigest == digest }
      raise "Updater reported failure" if File.read(File.join(directory, "updates/install.log")).include?("Package checksum mismatch")
      File.write(File.join(output, "passed.json"), JSON.pretty_generate(passed: true, version: "0.0.2",
        checks: %w[signed_feed verified_download restart actual_upgrade successful_install_result preserved_books preserved_reading_position preserved_preferences offline_search safely_queued_active_download resumed_download preserved_paused_download preserved_partial_file]))
      app.close
      next
    end
    case phase
    when 0
      next if app.instance_variable_get(:@update_state) == :restoring
      manifest = File.binread(ENV.fetch("ALJAM3_UPGRADE_MANIFEST"))
      artifact = ENV.fetch("ALJAM3_UPGRADE_PACKAGE")
      transport = ->(url, &block) do
        if url == Aljam3::Updates::FEED
          block.call(manifest)
        else
          File.open(artifact, "rb") { |file| while (part = file.read(65_536)); block.call(part); end }
        end
      end
      updater = Aljam3::Updates.new(directory:, resources: root, transport:)
      app.instance_variable_set(:@updater, updater)
      store.save_preference("update_sentinel", "مكتبة الجامع")
      queue = app.instance_variable_get(:@download_queue)
      [90_001, 90_002].each { |id| queue.enqueue(store.book(1).merge("id" => id)) }
      queue.pause(90_002)
      File.write(File.join(directory, "transfer.part"), "partially downloaded book")
      app.open_book(store.book(1))
      app.turn_page(72)
      app.check_updates
      phase = 1
    when 1
      state = app.instance_variable_get(:@update_state)
      raise "Update check/download failed" if state == :error
      next unless state == :ready && app.instance_variable_get(:@page_image)
      next unless app.instance_variable_get(:@download_queue).current&.dig(:bytes) == 40
      app.open_dialog(:updates)
      phase = 2
    when 2
      next if app.instance_variable_get(:@motion).active?
      automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
      automation.wait_frames
      automation.snapshot(File.join(output, "update-ready.png"), scale: 2)
      app.restart_for_update
      phase = 3
    end
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
