# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "timeout"

module PackageVerification
  def self.call(bundle:, home:, output:, probe: File.join(__dir__, "probe.rb"))
    root = File.expand_path("..", __dir__)
    windows = Gem.win_platform?
    FileUtils.mkdir_p([home, output])
    %w[passed.json failed.txt].each { |name| FileUtils.rm_f(File.join(output, name)) }
    launcher = File.join(bundle, windows ? "Aljam3.exe" : "Contents/MacOS/aljam3")
    system_path = windows ? [File.join(ENV.fetch("SystemRoot"), "System32"), ENV.fetch("SystemRoot")] : %w[/usr/bin /bin /usr/sbin /sbin]
    env = {
      "HOME" => home, "USERPROFILE" => home, "LOCALAPPDATA" => home,
      "ALJAM3_DATA_DIR" => File.join(home, "data"), "ALJAM3_API_URL" => "http://127.0.0.1:1",
      "ALJAM3_VERIFY_OUTPUT" => output, "SCARPE_RUN_FILE" => probe,
      "ALJAM3_BENCHMARK_PDF" => File.join(root, ".cache/smoke/books/1/1.pdf"),
      "SCARPE_NATIVE_HEADLESS" => "1", "SCARPE_NATIVE_GHOST" => nil,
      "PATH" => [File.join(root, "vendor/scarpe/spec/support/fakebin"), *system_path].join(File::PATH_SEPARATOR),
      "SPEC_CLIPBOARD_FILE" => File.join(home, "clipboard.txt"), "SPEC_TRAP_FILE" => File.join(home, "trapped.txt")
    }
    timeout = Integer(ENV.fetch("ALJAM3_VERIFY_TIMEOUT", "120"))
    stdout, status = Timeout.timeout(timeout) { Open3.capture2e(env, [launcher, launcher]) }
    puts stdout
    report = File.join(output, "passed.json")
    unless status.success? && File.file?(report) && JSON.parse(File.read(report)).fetch("passed")
      [File.join(output, "failed.txt"), File.join(home, "data/launcher.log")].each { |path| warn File.read(path) if File.file?(path) }
      raise "Packaged application verification failed"
    end
    puts File.read(report)
  end
end
