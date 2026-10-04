# frozen_string_literal: true

require "json"

module MotionReport
  def self.call(directory)
    benchmark = JSON.parse(File.read(File.join(directory, "passed.json")))
    native = JSON.parse(File.read(File.join(directory, "rust.json")))
    samples = benchmark.fetch("samples")
    frames_for = ->(sample) do
      native.fetch("frames").select do |frame|
        time = native.fetch("started_unix") + frame.first
        time.between?(sample.fetch("started"), sample.fetch("finished"))
      end
    end
    frames = samples.flat_map(&frames_for).uniq
    raise "No animation frames recorded" if frames.empty?
    if benchmark.fetch("ghost") && native.fetch("phases").fetch("present").fetch("n").zero?
      raise "Ghost verification did not present real native frames"
    end
    # Request handling includes rendering too, so summing it would double count.
    work = frames.map { |frame| frame[1..5].sum }
    interactions = samples.group_by { |sample| sample.fetch("name") }.to_h do |name, runs|
      gaps = runs.flat_map { |sample| frames_for.call(sample).each_cons(2).map { |a, b| (b[0] - a[0]) * 1000 } }
      costs = runs.flat_map { |sample| frames_for.call(sample).map { |frame| frame[1..5].sum } }
      [name, { frame_work_ms: distribution(costs), frame_interval_ms: distribution(gaps),
        gaps_over_33ms: gaps.count { |gap| gap > 1000.0 / 30 }, intervals: gaps.length }]
    end
    report = { ghost: benchmark.fetch("ghost"), frames: frames.length, transfer_bytes: benchmark.fetch("transfer_bytes"),
      frame_work_ms: distribution(work), interactions:, counters: native.fetch("counters"),
      note: "Frame intervals cover active transitions only. Headless runs measure work; ghost runs also include OS presentation scheduling." }
    File.write(File.join(directory, "performance.json"), JSON.pretty_generate(report))
    puts JSON.pretty_generate(report)
    report
  end

  def self.distribution(values)
    return nil if values.empty?

    values = values.sort
    { median: values[values.length / 2].round(2), p95: values[(values.length * 0.95).floor].round(2), max: values.last.round(2) }
  end
end
