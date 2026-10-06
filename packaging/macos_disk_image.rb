# frozen_string_literal: true

require "tmpdir"

module MacDiskImage
  def self.mount(image)
    raise "Mount disk images on macOS" unless RUBY_PLATFORM.include?("darwin")
    Dir.mktmpdir("aljam3-mounted-") do |mount|
      raise "Disk image mounting failed" unless system("hdiutil", "attach", "-quiet", "-readonly", "-noautoopen", "-mountpoint", mount, image)
      begin
        yield mount
      ensure
        raise "Disk image ejection failed" unless system("hdiutil", "detach", "-quiet", mount)
      end
    end
  end
end
