# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/aljam3/language"

class LanguageTest < Minitest::Test
  def test_arabic_locales_use_the_arabic_brand
    %w[ar ar-IQ ar_SA ar-EG].each { |locale| assert_equal "الجامع", Aljam3::Language.app_name(locale) }
  end

  def test_other_languages_use_the_english_brand
    ["en", "en-US", "fr-FR", "C.UTF-8", nil].each { |locale| assert_equal "Aljam3", Aljam3::Language.app_name(locale) }
    refute_empty Aljam3::Language.preferred
  end
end
