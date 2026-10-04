# frozen_string_literal: true

require_relative "test_helper"

class NotificationsTest < Minitest::Test
  def setup
    @now = 0.0
    @notices = Aljam3::Notifications.new(clock: -> { @now })
  end

  def add(key, **options)
    @notices.push(key, **options) { |count| { message: "#{key}: #{count}" } }
  end

  def tick(seconds, **options)
    @now += seconds
    @notices.tick(**options)
  end

  def test_a_waiting_notice_gets_its_own_five_seconds
    add(:download)
    add(:export)
    tick(5)
    assert_equal :export, @notices.current.fetch(:key)
    tick(4)
    assert @notices.current
    tick(1)
    assert_nil @notices.current
  end

  def test_dialogs_hover_and_keyboard_focus_pause_expiry
    add(:download)
    tick(2)
    tick(60, paused: true)
    tick(2)
    assert @notices.current
    tick(1)
    assert_nil @notices.current
  end

  def test_repeated_completions_are_grouped_and_reset_the_reading_time
    add(:download)
    tick(4)
    1_000.times { add(:download) }
    assert_equal 1_001, @notices.current.fetch(:count)
    tick(4)
    assert @notices.current
    tick(1)
    assert_nil @notices.current
  end

  def test_a_failure_remains_until_dismissed_without_losing_waiting_results
    add(:failure, persistent: true)
    add(:export)
    tick(3_600)
    assert_equal :failure, @notices.current.fetch(:key)
    @notices.dismiss
    assert_equal :export, @notices.current.fetch(:key)
    tick(4)
    assert @notices.current
  end
end
