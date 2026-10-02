# frozen_string_literal: true

require "cgi"

module Aljam3
  module Text
    module_function

    def without_tashkeel(text)
      text.gsub(/[\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06ed]/, "")
    end

    def normalize(text)
      text.to_s.unicode_normalize(:nfkc)
        .gsub(/[\u0610-\u061a\u0640\u064b-\u065f\u0670\u06d6-\u06ed]/, "")
        .tr("أإآٱى", "ااااي").downcase
    end

    def plain(text)
      CGI.unescapeHTML(text.to_s.gsub(%r{</?mark>}, "")).gsub(/&nbsp;|\u00a0/, " ")
    end

    def excerpt(text, query = "", length: 320)
      words = plain(text).split
      term = normalize(query).split.first
      match = words.index { |word| term && normalize(word).include?(term) } || 0
      start = [match - 10, 0].max
      text = words.drop(start).join(" ")
      "#{'…' if start.positive?}#{text[0, length]}#{'…' if text.length > length}"
    end

    # Quote every token: punctuation and FTS operators in user input remain data.
    def match_query(query)
      normalize(query).scan(/[[:alnum:]]+/).map { |word| %Q("#{word}"*) }.join(" AND ")
    end

    def match_ranges(text, query)
      fold = ->(value) { normalize(value).tr("ة٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹", "ه01234567890123456789") }
      terms = fold.call(query).scan(/[[:alnum:]]+/)
      return [] if terms.empty?

      ranges = []
      text.to_enum(:scan, /[\p{L}\p{M}\p{N}]+/).each do
        match = Regexp.last_match
        ranges << [match.begin(0), match[0].length] if terms.any? { |term| fold.call(match[0]).include?(term) }
      end
      ranges
    end
  end
end
