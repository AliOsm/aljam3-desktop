# frozen_string_literal: true

module Aljam3
  module Desktop
    def self.reveal(path)
      raise Errno::ENOENT, path unless File.file?(path)

      command = if Gem.win_platform?
        ["explorer.exe", File.dirname(path).tr("/", "\\")]
      elsif RUBY_PLATFORM.include?("darwin")
        ["open", "-R", path]
      else
        ["xdg-open", File.dirname(path)]
      end
      Process.detach(Process.spawn(*command, out: File::NULL, err: File::NULL))
    end
  end
end
