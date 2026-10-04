# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../packaging/motion_report"

class MotionReportTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("aljam3-motion-report-")
    File.write(File.join(@directory, "passed.json"), JSON.generate(
      ghost: true, native_timing: true, transfer_bytes: 1024,
      samples: [{ name: "reader_options/ruby_busy", started: 100, finished: 100.1, ruby_busy: [100, 100.09] }]
    ))
    @native = { started_unix: 100, phases: { present: { n: 1 } }, counters: {}, frames: [[0.07, 1, 1, 1, 1, 1]] }
    write_native
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_current_package_must_keep_animating_while_ruby_is_busy
    capture_io do
      error = assert_raises(RuntimeError) { MotionReport.call(@directory) }
      assert_includes error.message, "Native animations stopped while Ruby was busy"
    end
    @native[:frames].unshift([0.03, 1, 1, 1, 1, 1])
    write_native
    capture_io { assert_equal [2], MotionReport.call(@directory).fetch(:frames_while_ruby_busy) }
  end

  def test_baseline_keeps_measurements_when_an_older_app_drops_frames
    capture_io do
      report = MotionReport.call(@directory, verify_animation: false)
      assert_equal [1], report.fetch(:frames_while_ruby_busy)
      assert_equal 1, report.fetch(:frames)
    end
    saved = JSON.parse(File.read(File.join(@directory, "performance.json")))
    assert_equal [1], saved.fetch("frames_while_ruby_busy")
  end

  def test_baseline_still_rejects_missing_animation_measurements
    @native[:frames] = []
    write_native
    error = assert_raises(RuntimeError) { MotionReport.call(@directory, verify_animation: false) }
    assert_equal "No animation frames recorded", error.message
  end

  def test_baseline_still_requires_native_presentation
    @native[:phases][:present][:n] = 0
    write_native
    error = assert_raises(RuntimeError) { MotionReport.call(@directory, verify_animation: false) }
    assert_equal "Ghost verification did not present real native frames", error.message
  end

  private

  def write_native
    File.write(File.join(@directory, "rust.json"), JSON.generate(@native))
  end
end
