# frozen_string_literal: true

require_relative "test_helper"

class TextTest < Minitest::Test
  def test_matches_keep_original_character_offsets_and_diacritics
    content = "تمهيد؛ الْعِـلْمِ نور، والعلمُ حياة."
    matches = Aljam3::Text.match_ranges(content, "العلم")
    assert_equal ["الْعِـلْمِ", "والعلمُ"], matches.map { |start, length| content[start, length] }
    assert_equal content.index("الْعِـلْمِ"), matches.first.first
  end

  def test_letter_and_digit_variants_are_highlighted
    content = "في الْمَدْرَسَةِ سنة ١٢٣ و۱۲۳ عن الإيمان"
    matches = Aljam3::Text.match_ranges(content, "مدرسه 123 ايمان")
    assert_equal ["الْمَدْرَسَةِ", "١٢٣", "و۱۲۳", "الإيمان"], matches.map { |start, length| content[start, length] }
    assert_empty Aljam3::Text.match_ranges(content, '" * ()')
    assert_empty Aljam3::Text.match_ranges(content, "")
  end
end
