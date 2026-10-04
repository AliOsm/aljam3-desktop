# frozen_string_literal: true

module Aljam3
  module ExportName
    def self.build(title, extension, part: nil, page: nil)
      stem = [title, part, ("صفحة #{page}" if page)].compact.join(" - ")
        .gsub(/[<>:"\\\/|?*\x00-\x1f]/, " ").gsub(/\s+/, " ").strip
        .sub(/\.(pdf|txt|docx|png)\z/i, "").gsub(/[. ]+\z/, "")
      stem = "الجامع" if stem.empty?
      "#{stem.byteslice(0, 240).scrub('').rstrip}.#{extension}"
    end
  end
end
