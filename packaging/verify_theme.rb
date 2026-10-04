# frozen_string_literal: true

require "json"

module ThemeVerification
  # Trace the actual startup path, including very short-lived commands that a
  # window/process polling check could miss. The detached launcher is unchanged.
  def self.call(output:, system_reads:)
    reads = 0
    query_thread = nil
    trace = TracePoint.new(:call, :return, :c_call) do |event|
      if event.method_id == :system_theme && event.defined_class.name == "Aljam3::UI::Theme"
        if event.event == :call
          reads += 1
          query_thread = Thread.current
        else
          query_thread = nil
        end
      elsif query_thread == Thread.current && event.event == :c_call && Gem.win_platform? &&
          %i[spawn system exec popen `].include?(event.method_id)
        raise "Windows theme detection attempted to launch a subprocess: #{event.method_id}"
      end
    end
    trace.enable { yield }
    raise "Expected #{system_reads} system theme reads, got #{reads}" unless reads == system_reads

    File.write(File.join(output, "theme-startup.json"), JSON.pretty_generate({ passed: true,
      system_reads: reads, windows_subprocess_check: Gem.win_platform? }))
  end
end
