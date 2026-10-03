# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/catalog"

class SearchControlsTest < Minitest::Test
  class View
    include Aljam3::UI::Catalog
    attr_accessor :screen, :mode, :query, :filters
    attr_reader :request_count, :draw_count

    def initialize
      @screen, @mode, @query, @filters = :home, :content, "", {}
      @request_count = @draw_count = 0
    end

    def request_catalog = @request_count += 1
    def draw_window = @draw_count += 1
  end

  def test_home_mode_selection_waits_for_a_query
    view = View.new
    view.switch_search_mode(:books)
    assert_equal :books, view.mode
    assert_equal 0, view.request_count
    assert_equal 1, view.draw_count
  end

  def test_switching_mode_keeps_the_query_and_restores_compatible_filters
    view = View.new
    view.query = "العلم"
    view.filters = { category: 2, author: 4 }
    view.switch_search_mode(:books)
    assert_empty view.filters
    view.filters = { library: 3 }
    view.switch_search_mode(:content)
    assert_equal "العلم", view.query
    assert_equal({ category: 2, author: 4 }, view.filters)
    view.switch_search_mode(:books)
    assert_equal({ library: 3 }, view.filters)
    assert_equal 3, view.request_count
  end

  def test_browsing_refreshes_even_without_a_query
    view = View.new
    view.screen = :browse
    view.refresh_search
    assert_equal 1, view.request_count
  end
end
