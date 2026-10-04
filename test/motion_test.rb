# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/motion"

class MotionTest < Minitest::Test
  class View
    def initialize(**values) = @values = values
    def style(**values) = values.empty? ? @values : @values.merge!(values)
  end

  Timer = Struct.new(:removed) do
    def remove = self.removed = true
  end

  def setup
    @now, @timers = 0.0, []
    @motion = Aljam3::Motion.new(clock: -> { @now }, schedule: ->(&_) { Timer.new(false).tap { |timer| @timers << timer } })
    @view = View.new(opacity: 0.0, top: 8.0)
  end

  def advance(seconds)
    @now += seconds
    @motion.tick
  end

  def test_uses_elapsed_time_skips_missed_frames_and_removes_the_only_timer
    @motion.to(@view, opacity: 1.0, top: 0.0, duration: 0.2, group: :dialog)
    advance(0.1)
    assert_in_delta 0.875, @view.style[:opacity]
    assert_in_delta 1.0, @view.style[:top]
    advance(0.3)
    assert_equal({ opacity: 1.0, top: 0.0 }, @view.style)
    assert_equal 1, @timers.length
    assert @timers.first.removed
    refute @motion.active?
  end

  def test_reversal_starts_where_the_panel_is_and_drops_obsolete_completion
    completed = []
    @motion.to(@view, opacity: 1.0, duration: 0.2, group: :dialog, complete: -> { completed << :opened })
    advance(0.05)
    before = @view.style[:opacity]
    @motion.to(@view, opacity: 0.0, duration: 0.1, group: :dialog, complete: -> { completed << :closed })
    assert_equal before, @view.style[:opacity]
    advance(0.05)
    assert_operator @view.style[:opacity], :<, before
    advance(0.1)
    assert_equal [:closed], completed
  end

  def test_repeated_progress_updates_do_not_restart_the_same_transition
    @motion.to(@view, opacity: 0.4, duration: 0.2, group: :content)
    advance(0.1)
    @motion.to(@view, opacity: 0.4, duration: 0.2, group: :content)
    advance(0.1)
    assert_equal 0.4, @view.style[:opacity]
    refute @motion.active?
  end

  def test_reduced_motion_finishes_pending_work_and_never_starts_a_new_timer
    completed = false
    @motion.to(@view, opacity: 1.0, duration: 0.2, group: :dialog, complete: -> { completed = true })
    @motion.reduced = true
    assert completed
    assert_equal 1.0, @view.style[:opacity]
    assert @timers.first.removed
    @motion.to(@view, opacity: 0.0, duration: 0.1, group: :dialog)
    assert_equal 0.0, @view.style[:opacity]
    assert_equal 1, @timers.length
  end

  def test_removing_a_layer_cancels_its_jobs_without_running_stale_callbacks
    completed = []
    other = View.new(fraction: 0.0)
    @motion.to(@view, opacity: 1.0, duration: 0.1, group: :dialog, complete: -> { completed << :dialog })
    @motion.to(other, fraction: 0.8, duration: 0.1, group: :content, complete: -> { completed << :content })
    @motion.cancel(:dialog)
    advance(0.2)
    assert_equal [:content], completed
    assert_equal 0.0, @view.style[:opacity]
    assert_equal 0.8, other.style[:fraction]
    assert_equal 1, @timers.length
  end
end
