# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/pdf_viewport"

class PDFViewportTest < Minitest::Test
  def setup
    @view = Aljam3::PDFViewport.new(count: 10_000)
    @view.resize(width: 560, height: 480, zoom: 1.0)
  end

  def test_only_nearby_pages_are_requested_at_either_end_and_after_a_large_seek
    [1, 5000, 10_000].each do |page|
      top = @view.top(page)
      assert_includes @view.visible(top), page
      assert_equal page, @view.active(top)
      assert_operator @view.nearby(top).size, :<=, 5
      assert_equal top, @view.clamp(top)
    end
    assert_equal 1, @view.page_at(-100)
    assert_equal 10_000, @view.page_at(@view.total_height + 100)
  end

  def test_zoom_and_mixed_page_sizes_preserve_the_reading_anchor
    top = @view.top(5000) + 180
    anchor = @view.anchor(top)
    @view.resize(width: 740, height: 500, zoom: 2.5)
    assert_equal anchor.first, @view.anchor(@view.position(anchor)).first
    assert_in_delta anchor[1], @view.anchor(@view.position(anchor))[1], 0.0001
    @view.learn(4999, width: 1200, height: 300)
    @view.learn(5000, width: 500, height: 2000)
    assert_in_delta anchor[1], @view.anchor(@view.position(anchor))[1], 0.0001
    assert_equal [293, 1170], @view.dimensions(5000)
  end

  def test_last_page_can_be_aligned_even_when_landscape_or_zoomed_out
    @view.learn(10_000, width: 1600, height: 300)
    @view.resize(width: 560, height: 480, zoom: 0.5)
    assert_equal @view.top(10_000), @view.clamp(@view.top(10_000))
    assert_equal 10_000, @view.active(@view.top(10_000))
  end

  def test_a_fully_visible_landscape_page_remains_active_above_a_partial_portrait
    @view.learn(3, width: 600, height: 240)
    assert_equal 3, @view.active(@view.top(3))
    anchor = @view.anchor(@view.top(10_000), at: 0)
    @view.learn(10_000, width: 600, height: 240)
    assert_equal @view.top(10_000), @view.position(anchor)
  end
end
