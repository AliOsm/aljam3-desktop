# frozen_string_literal: true

module Aljam3
  module ExportName
    def self.build(title, extension, part: nil, page: nil)
      suffix = [shorten(clean(part), 100), ("صفحة #{page}" if page)].compact.reject(&:empty?).join(" - ")
      suffix = " - #{suffix}" unless suffix.empty?
      title = clean(title)
      title = "الجامع" if title.empty?
      stem = shorten(title, 240 - suffix.bytesize) + suffix
      stem = "_#{stem}" if stem.match?(/\A(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)(?:\.|\z)/i)
      "#{stem}.#{extension}"
    end

    def self.clean(text)
      text.to_s.gsub(/[<>:"\\\/|?*\x00-\x1f]/, " ").gsub(/\s+/, " ").strip
        .sub(/\.(pdf|txt|docx|png)\z/i, "").gsub(/[. ]+\z/, "")
    end

    def self.shorten(text, bytes)
      return text if text.bytesize <= bytes

      first = (bytes - 3) / 2
      last = bytes - 3 - first
      "#{text.byteslice(0, first).scrub('')}…#{text.byteslice(-last, last).scrub('')}"
    end

    private_class_method :clean, :shorten
  end
end
