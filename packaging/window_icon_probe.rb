# frozen_string_literal: true

# Inspect the actual Windows window, off-screen on a disposable CI runner.
# The launcher's environment stays headless so failures cannot open a dialog.
raise "Window icon checks require Windows CI" unless Gem.win_platform? && ENV["GITHUB_ACTIONS"] == "true"
ENV.delete("SCARPE_NATIVE_HEADLESS")
ENV["SCARPE_NATIVE_GHOST"] = "1"

require "ffi"
require "json"
require "chunky_png"

module WindowIcons
  extend FFI::Library
  ffi_lib "user32", "gdi32"
  callback :enum_window, [:pointer, :intptr_t], :int
  attach_function :EnumWindows, [:enum_window, :intptr_t], :int
  attach_function :GetWindowThreadProcessId, [:pointer, :pointer], :uint32
  attach_function :GetWindowTextW, [:pointer, :pointer, :int], :int
  attach_function :SendMessageW, [:pointer, :uint32, :uintptr_t, :intptr_t], :intptr_t
  attach_function :GetIconInfo, [:pointer, :pointer], :int
  attach_function :GetObjectW, [:pointer, :int, :pointer], :int
  attach_function :CreateCompatibleDC, [:pointer], :pointer
  attach_function :GetDIBits, [:pointer, :pointer, :uint, :uint, :pointer, :pointer, :uint], :int
  attach_function :DeleteDC, [:pointer], :int
  attach_function :DeleteObject, [:pointer], :int

  class IconInfo < FFI::Struct
    layout :icon, :int, :x, :uint32, :y, :uint32, :mask, :pointer, :color, :pointer
  end

  class Bitmap < FFI::Struct
    layout :type, :long, :width, :long, :height, :long, :row_bytes, :long,
      :planes, :ushort, :bits_per_pixel, :ushort, :bits, :pointer
  end

  def self.window_for(pid, title)
    found = nil
    process = FFI::MemoryPointer.new(:uint32)
    text = FFI::MemoryPointer.new(:uint16, 512)
    EnumWindows(lambda do |window, _|
      GetWindowThreadProcessId(window, process)
      if process.read_uint32 == pid
        length = GetWindowTextW(window, text, 512)
        found = window if text.read_bytes(length * 2).force_encoding("UTF-16LE").encode("UTF-8") == title
      end
      found ? 0 : 1
    end, 0)
    found
  end

  def self.image(window, kind)
    handle = SendMessageW(window, 0x007f, kind, 0) # WM_GETICON: 0 small, 1 big
    raise "Windows has no #{kind.zero? ? 'title-bar' : 'taskbar'} icon" if handle.zero?

    info = IconInfo.new
    raise "Cannot read Windows icon" if GetIconInfo(FFI::Pointer.new(handle), info).zero?
    bitmap = Bitmap.new
    raise "Cannot read icon bitmap" if GetObjectW(info[:color], bitmap.size, bitmap).zero?
    width, height = bitmap[:width], bitmap[:height]
    header = [40, width, -height, 1, 32, 0, width * height * 4, 0, 0, 0, 0].pack("L<l<l<S<S<L<L<l<l<L<L<")
    pixels = FFI::MemoryPointer.new(:uint8, width * height * 4)
    dc = CreateCompatibleDC(nil)
    raise "Cannot read icon pixels" unless GetDIBits(dc, info[:color], 0, height, pixels, FFI::MemoryPointer.from_string(header), 0) == height

    rgba = pixels.read_bytes(width * height * 4)
    (0...rgba.bytesize).step(4) do |offset|
      blue, red = rgba.getbyte(offset), rgba.getbyte(offset + 2)
      rgba.setbyte(offset, red)
      rgba.setbyte(offset + 2, blue)
    end
    ChunkyPNG::Image.from_rgba_stream(width, height, rgba)
  ensure
    DeleteDC(dc) if dc && !dc.null?
    if info
      %i[mask color].each { |key| DeleteObject(info[key]) unless info[key].null? }
    end
  end
end

output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
root = ENV.fetch("ALJAM3_BUNDLE_ROOT")
load File.join(root, "app/app.rb")
app = Shoes.APPS.first
expected = ChunkyPNG::Image.from_file(File.join(Aljam3::ROOT, "assets/brand/app-icon.png"))
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
app.every(0.1) do
  begin
    raise "Window icon check timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 20
    service = Shoes::DisplayService.display_service
    title = service.query_display_drawable_for(app.linkable_id).props.fetch("title")
    window = WindowIcons.window_for(service.child.pid, title)
    next unless window

    Scarpe::Native::Automation.new(service).wait_frames
    %w[titlebar taskbar].each_with_index do |name, kind|
      image = WindowIcons.image(window, kind)
      image.save(File.join(output, "#{name}.png"))
      raise "Wrong #{name} icon pixels" unless image == expected
    end
    File.write(File.join(output, "passed.json"), JSON.pretty_generate({ passed: true,
      checks: %w[titlebar_icon_pixels taskbar_icon_pixels], width: expected.width, height: expected.height }))
    app.close
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
