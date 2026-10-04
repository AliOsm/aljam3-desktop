# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/motion"

class MotionTest < Minitest::Test
  class View
    def initialize(**values) = @values = values
    def style(**values) = values.empty? ? @values : @values.merge!(values)
  end

  class Driver
    attr_reader :jobs, :cancelled
    def initialize = (@jobs, @cancelled = [], [])
    def transition(view, duration:, **values, &complete)
      @jobs << { view:, values:, duration:, complete: }
      @jobs.length
    end
    def cancel_transition(token) = @cancelled << token
    def finish(token)
      job = @jobs.fetch(token - 1)
      job[:view].style(**job[:values]) unless @cancelled.include?(token)
      job[:complete].call
    end
  end

  def setup
    @driver = Driver.new
    @motion = Aljam3::Motion.new(driver: @driver)
    @view = View.new(opacity: 0.0, displace_top: 8.0)
  end

  def test_submits_one_destination_and_waits_for_native_completion
    completed = false
    @motion.to(@view, opacity: 1.0, displace_top: 0.0, duration: 0.2, group: :dialog, complete: -> { completed = true })
    assert_equal 1, @driver.jobs.length
    assert_equal 0.0, @view.style[:opacity]
    assert @motion.active?
    refute completed
    @driver.finish(1)
    assert completed
    refute @motion.active?
  end

  def test_retarget_cancels_previous_job_without_resetting_displayed_values
    completed = []
    @motion.to(@view, opacity: 1.0, duration: 0.2, group: :dialog, complete: -> { completed << :opened })
    @view.style(opacity: 0.6)
    @motion.to(@view, opacity: 0.0, duration: 0.1, group: :dialog, complete: -> { completed << :closed })
    assert_equal [1], @driver.cancelled
    assert_equal 0.6, @view.style[:opacity]
    @driver.finish(1) # a queued, obsolete completion must not clean up a newer panel
    assert_empty completed
    assert @motion.active?
    @driver.finish(2)
    assert_equal [:closed], completed
  end

  def test_repeated_progress_updates_do_not_restart_the_same_transition
    3.times { @motion.to(@view, opacity: 0.4, duration: 0.2, group: :content) }
    assert_equal 1, @driver.jobs.length
    @driver.finish(1)
    refute @motion.active?
  end

  def test_reduced_motion_finishes_pending_work_and_submits_no_more_animations
    completed = false
    @motion.to(@view, opacity: 1.0, duration: 0.2, group: :dialog, complete: -> { completed = true })
    @motion.reduced = true
    assert completed
    assert_equal 1.0, @view.style[:opacity]
    assert_equal [1], @driver.cancelled
    @motion.to(@view, opacity: 0.0, duration: 0.1, group: :dialog)
    assert_equal 0.0, @view.style[:opacity]
    assert_equal 1, @driver.jobs.length
    refute @motion.active?
  end

  def test_navigation_cancels_only_the_removed_layers
    completed = []
    other = View.new(fraction: 0.0)
    @motion.to(@view, opacity: 1.0, duration: 0.1, group: :dialog, complete: -> { completed << :dialog })
    @motion.to(other, fraction: 0.8, duration: 0.1, group: :content, complete: -> { completed << :content })
    @motion.cancel(:dialog)
    @driver.finish(1)
    @driver.finish(2)
    assert_equal [:content], completed
    assert_equal 0.8, other.style[:fraction]
    refute @motion.active?
  end
end
