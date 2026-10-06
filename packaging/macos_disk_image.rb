# frozen_string_literal: true

require "tmpdir"

module MacDiskImage
  def self.detach(mount)
    return if system("hdiutil", "detach", "-quiet", mount)

    # Finder can briefly keep a disk open after its window has closed.
    raise "Disk image ejection failed" unless system("hdiutil", "detach", "-force", "-quiet", mount)
  end

  def self.mount(image)
    raise "Mount disk images on macOS" unless RUBY_PLATFORM.include?("darwin")
    Dir.mktmpdir("aljam3-mounted-") do |mount|
      raise "Disk image mounting failed" unless system("hdiutil", "attach", "-quiet", "-readonly", "-noautoopen", "-mountpoint", mount, image)
      begin
        yield mount
      ensure
        detach(mount)
      end
    end
  end
end
