# frozen_string_literal: true

require "ffi"

module Aljam3
  module Language
    def self.app_name(language = preferred)
      language.to_s.split(/[-_]/).first == "ar" ? "الجامع" : "Aljam3"
    end

    def self.preferred
      if Gem.win_platform?
        Native.GetUserDefaultUILanguage & 0x3ff == 1 ? "ar" : "en"
      elsif RUBY_PLATFORM.include?("darwin")
        languages = Native.CFLocaleCopyPreferredLanguages
        return "en" if languages.null?

        begin
          return "en" if Native.CFArrayGetCount(languages).zero?

          language = Native.CFArrayGetValueAtIndex(languages, 0)
          buffer = FFI::MemoryPointer.new(:char, 128)
          Native.CFStringGetCString(language, buffer, buffer.size, 0x08000100) ? buffer.read_string : "en"
        ensure
          Native.CFRelease(languages)
        end
      else
        ENV["LC_ALL"] || ENV["LC_MESSAGES"] || ENV["LANG"] || "en"
      end
    end

    module Native
      extend FFI::Library
      if Gem.win_platform?
        ffi_lib "kernel32"
        attach_function :GetUserDefaultUILanguage, [], :uint16
      elsif RUBY_PLATFORM.include?("darwin")
        ffi_lib "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
        attach_function :CFLocaleCopyPreferredLanguages, [], :pointer
        attach_function :CFArrayGetCount, [:pointer], :long
        attach_function :CFArrayGetValueAtIndex, [:pointer, :long], :pointer
        attach_function :CFStringGetCString, [:pointer, :pointer, :long, :uint32], :bool
        attach_function :CFRelease, [:pointer], :void
      end
    end
  end
end
