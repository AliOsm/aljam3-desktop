# frozen_string_literal: true
require_relative "test_helper"
require_relative "../lib/aljam3/navigation_history"

class NavigationHistoryTest < Minitest::Test
  def test_back_forward_and_branching
    history = Aljam3::NavigationHistory.new
    home = { screen: :home }
    books = { screen: :browse, query: "العلم", filters: { author: 4 }, scroll: 120 }
    reader = { screen: :reader, book: 1, page: 104 }
    history.visit(home)
    history.visit(books)
    assert_equal books, history.move(:back, reader)
    assert_equal home, history.move(:back, books)
    assert_nil history.move(:back, home)
    assert_equal books, history.move(:forward, home)
    assert_equal reader, history.move(:forward, books)
    assert_equal books, history.move(:back, reader)
    history.visit(books)
    assert_nil history.move(:forward, { screen: :categories })
  end

  def test_history_has_a_memory_bound_and_deduplicates
    history = Aljam3::NavigationHistory.new
    80.times { |i| history.visit(i) }
    history.visit(79)
    60.times { |i| assert_equal 79 - i, history.move(:back, 80 - i) }
    refute history.back?
    assert_nil history.move(:back, 20)
  end
end
