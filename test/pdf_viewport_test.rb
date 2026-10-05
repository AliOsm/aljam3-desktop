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

  def test_top_anchor_keeps_the_fraction_of_a_page_for_integer_scroll_events
    offset = @view.top(5) + 123
    anchor = @view.anchor(offset, at: 0)
    assert_in_delta offset, @view.position(anchor), 0.001
    @view.learn(5, width: 480, height: 640)
    assert_in_delta offset, @view.position(anchor), 0.001
    @view.learn(3, width: 1200, height: 300)
    assert_in_delta @view.top(5) + 123, @view.position(anchor), 0.001
  end

  def test_a_fully_visible_landscape_page_remains_active_above_a_partial_portrait
    @view.learn(3, width: 600, height: 240)
    assert_equal 3, @view.active(@view.top(3))
    anchor = @view.anchor(@view.top(10_000), at: 0)
    @view.learn(10_000, width: 600, height: 240)
    assert_equal @view.top(10_000), @view.position(anchor)
  end

  def test_pointer_anchor_excludes_fixed_gaps_and_does_not_drift_in_long_gestures
    [1, 5000, 10_000].each do |page|
      [[600, 240], [600, 850], [240, 700]].each do |w, h|
        @view.learn(page, width: w, height: h)
        @view.resize(width: 560, height: 480, zoom: 1.0)
        scroll = @view.top(page)
        x, y = 280, [@view.dimensions(page).last * 0.4, 220].min
        anchor = @view.point_anchor(scroll, x:, y:)
        (1..200).each do |step|
          zoom = 1.0 + Math.sin(step * Math::PI / 200) * 2
          @view.resize(width: 560, height: 480, zoom:)
          offset, pan = @view.point_position(anchor)
          nw, nh = @view.dimensions(page)
          assert_in_delta x, @view.page_left(page, pan:) + anchor[1] * nw, 0.51
          desired = @view.top(page) + Aljam3::PDFViewport::GAP / 2.0 + anchor[2] * nh - y
          if desired.between?(0, @view.total_height - @view.height)
            assert_in_delta y, @view.top(page) + Aljam3::PDFViewport::GAP / 2.0 + anchor[2] * nh - offset, 0.51
          else
            assert_equal page == 1 ? 0 : @view.total_height - @view.height, offset
          end
        end
        assert_equal scroll, @view.point_position(anchor).first
      end
    end
  end

  def test_off_center_pointer_anchor_and_pan_survive_mixed_geometry
    @view.resize(width: 560, height: 480, zoom: 2.0)
    @view.learn(5, width: 600, height: 240)
    anchor = @view.point_anchor(@view.top(5) + 100, x: 170, y: 130, pan: 30)
    @view.learn(3, width: 240, height: 700)
    @view.resize(width: 560, height: 480, zoom: 2.7)
    offset, pan = @view.point_position(anchor)
    w, h = @view.dimensions(5)
    assert_in_delta 170, @view.page_left(5, pan:) + anchor[1] * w, 0.51
    assert_in_delta 130, @view.top(5) + 8 + anchor[2] * h - offset, 0.51
  end

  def test_zoom_edges_are_bounded_and_narrow_pages_can_move_within_whitespace
    [0.5, 1.0, 3.0].each do |zoom|
      @view.resize(width: 560, height: 480, zoom:)
      [1, 10_000].each do |page|
        [-100_000, 100_000].each do |far|
          offset, pan = @view.point_position([page, far, far, 100, 100])
          assert_equal @view.clamp(offset), offset
          assert_operator pan.abs, :<=, @view.pan_limit(page)
        end
      end
    end
    @view.resize(width: 560, height: 480, zoom: 1.0)
    anchor = @view.point_anchor(@view.top(5), x: 240, y: 160)
    @view.resize(width: 560, height: 480, zoom: 1.2)
    _, pan = @view.point_position(anchor)
    refute_equal 0, pan
    assert_in_delta 240, @view.page_left(5, pan:) + anchor[1] * @view.dimensions(5).first, 0.51
  end
end
