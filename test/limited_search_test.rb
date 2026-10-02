# frozen_string_literal: true

require_relative "test_helper"

class LimitedSearchTest < StoreTestCase
  def setup
    super
    @store.prepare_download(book)
    rows = Array.new(10_001) do |index|
      { "id" => index + 1, "number" => index + 1, "content" => "العلم العمل #{'تمهيد ' * 12}" }
    end
    rows.last["content"] = "العلم العمل"
    @store.add_pages(10, rows)
    @store.complete_download(1)
  end

  def test_default_pool_is_bounded_and_expansion_can_find_a_better_result
    first = @store.search("العلم العمل")
    assert_equal 10_000, first.dig("ranking", "candidates")
    assert first.dig("ranking", "has_more")
    refute first.dig("pagination", "count_is_exact")
    refute_includes first.fetch("pages").map { |hit| hit.fetch("id") }, 10_001
    assert_equal 20_000, first.dig("ranking", "next_pool_size")
    expanded = @store.search("العلم العمل", pool_size: 20_000)
    assert_equal 10_001, expanded.fetch("pages").first.fetch("id")
    refute expanded.dig("ranking", "has_more")
    assert_equal 10_001, expanded.dig("pagination", "count")
    assert expanded.dig("pagination", "count_is_exact")
  end

  def test_pool_pagination_is_stable_and_stops_at_the_candidate_boundary
    first = @store.search("العلم", pool_size: 25)
    ids = (1..3).flat_map { |page| @store.search("العلم", pool_size: 25, page:).fetch("pages").map { |hit| hit.fetch("id") } }
    assert_equal (1..25).to_a, ids
    assert_nil @store.search("العلم", pool_size: 25, page: 3).dig("pagination", "next_page")
    assert_equal first, @store.search("العلم", pool_size: 25)
    assert_equal 10_001, @store.search("العلم", order: "library", page: 834).fetch("pages").last.fetch("id")
  end

  def test_all_filters_and_download_eligibility_apply_before_the_cap
    other = book(2, category: 3).merge("author" => { "id" => 8, "name" => "مؤلف آخر" })
    @store.prepare_download(other)
    @store.add_pages(20, [{ "id" => 20_000, "number" => 1, "content" => "العلم العمل" }])
    assert_empty @store.search("العلم", book_id: 2, pool_size: 1).fetch("pages")
    @store.complete_download(2)
    result = @store.search("العلم", author: 8, category: 3, library: 3, pool_size: 1)
    assert_equal [20_000], result.fetch("pages").map { |hit| hit.fetch("id") }
    refute result.dig("ranking", "has_more")
    @store.discard_download(2)
    assert_empty @store.search("العلم", author: 8, category: 3, library: 3, pool_size: 1).fetch("pages")
  end
end
