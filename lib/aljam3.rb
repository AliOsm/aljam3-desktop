# frozen_string_literal: true

require_relative "aljam3/library"
require_relative "aljam3/downloader"
require_relative "aljam3/worker"

module Aljam3
  ROOT = File.expand_path("..", __dir__)

  def self.data_directory
    ENV.fetch("ALJAM3_DATA_DIR") do
      if RUBY_PLATFORM.include?("darwin")
        File.join(Dir.home, "Library", "Application Support", "Aljam3")
      elsif RUBY_PLATFORM.match?(/mingw|mswin/)
        File.join(ENV.fetch("LOCALAPPDATA", File.join(Dir.home, "AppData", "Local")), "Aljam3")
      else
        File.join(ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share")), "aljam3")
      end
    end
  end
end
