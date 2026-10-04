# frozen_string_literal: true

require "json"

module MotionReport
  def self.call(directory)
    benchmark = JSON.parse(File.read(File.join(directory, "passed.json")))
    native = JSON.parse(File.read(File.join(directory, "rust.json")))
    frames = native.fetch("frames").select do |frame|
      time = native.fetch("started_unix") + frame.first
      benchmark.fetch("intervals").any? { |first, last| time.between?(first, last) }
    end
    raise "No animation frames recorded" if frames.empty?
    if benchmark.fetch("ghost") && native.fetch("phases").fetch("present").fetch("n").zero?
      raise "Ghost verification did not present real native frames"
    end
    # Request handling includes rendering too, so summing it would double count.
    work = frames.map { |frame| frame[1..5].sum }.sort
    report = { ghost: benchmark.fetch("ghost"), frames: frames.length, transfer_bytes: benchmark.fetch("transfer_bytes"),
      frame_work_ms: { median: work[work.length / 2].round(2), p95: work[(work.length * 0.95).floor].round(2), max: work.last.round(2) } }
    File.write(File.join(directory, "performance.json"), JSON.pretty_generate(report))
    puts JSON.pretty_generate(report)
    report
  end
end
