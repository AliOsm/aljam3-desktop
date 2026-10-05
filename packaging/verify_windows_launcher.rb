# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "timeout"

module WindowsLauncherVerification
  def self.call(bundle:, home:, output:)
    root = File.expand_path("..", __dir__)
    launcher = File.join(bundle, "Aljam3.exe")
    script = File.join(home, "startup-failure.rb")
    File.write(script, 'abort "Deliberate startup failure"')
    env = { "SCARPE_NATIVE_HEADLESS" => "1", "SCARPE_RUN_FILE" => script,
      "HOME" => home, "USERPROFILE" => home, "LOCALAPPDATA" => home,
      "PATH" => [File.join(root, "vendor/scarpe/spec/support/fakebin"), ENV.fetch("PATH")].join(File::PATH_SEPARATOR),
      "SPEC_CLIPBOARD_FILE" => File.join(home, "clipboard.txt"), "SPEC_TRAP_FILE" => File.join(home, "trapped.txt"),
      "ALJAM3_DATA_DIR" => File.join(home, "startup-failure-data") }
    text, status = Timeout.timeout(30) { Open3.capture2e(env, [launcher, launcher]) }
    log = File.read(File.join(env.fetch("ALJAM3_DATA_DIR"), "launcher.log"))
    raise "Launcher hid the child failure" unless status.exitstatus == 1 && text.include?("Aljam3:") && log.include?("Deliberate startup failure")

    incomplete = File.join(home, "Incomplete app - الجامع")
    FileUtils.mkdir_p(incomplete)
    FileUtils.cp(launcher, incomplete)
    launcher = File.join(incomplete, "Aljam3.exe")
    env["ALJAM3_DATA_DIR"] = File.join(home, "missing-files-data")
    text, status = Timeout.timeout(30) { Open3.capture2e(env, [launcher, launcher]) }
    log = File.read(File.join(env.fetch("ALJAM3_DATA_DIR"), "launcher.log"))
    raise "Launcher hid missing app files" unless status.exitstatus == 1 && text.include?("برنامج التثبيت") && log.include?("برنامج التثبيت")

    File.write(File.join(output, "launcher-errors.json"), JSON.pretty_generate({ passed: true,
      checks: %w[child_failure_reported missing_files_reported] }))
  end
end
