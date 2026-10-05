# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class HTTPRangesTest < Minitest::Test
  class Interrupted < StandardError; end

  Client = Struct.new(:entered, :release, :closed, :fail_first) do
    def read_range(_url, offset:, check:, **)
      check.call
      entered << offset
      release.pop
      raise Interrupted if fail_first && offset.zero?

      check.call
      offset
    end

    def close = closed << true
  end

  def batch(count:, fail_first: false)
    http = Aljam3::HTTP.new
    entered, release, closed = Queue.new, Queue.new, Queue.new
    factory = -> { Client.new(entered, release, closed, fail_first) }
    Aljam3::HTTP.stub(:new, factory) do
      worker = Thread.new { http.read_ranges("https://example.test/book", ranges: count.times.map { |n| [n, 1] }) }
      worker.report_on_exception = false
      Timeout.timeout(5) { yield worker, entered, release, closed }
    ensure
      worker&.kill&.join if worker&.alive?
    end
  end

  def test_scattered_ranges_use_at_most_eight_connections_and_preserve_order
    batch(count: 16) do |worker, entered, release, closed|
      assert_equal (0...8).to_a, 8.times.map { entered.pop }.sort
      assert entered.empty?
      8.times { release << true }
      assert_equal (8...16).to_a, 8.times.map { entered.pop }.sort
      8.times { release << true }
      assert_equal (0...16).to_a, worker.value
      assert_equal 8, closed.size
    end
  end

  def test_a_failed_batch_joins_its_workers_and_closes_every_connection
    batch(count: 8, fail_first: true) do |worker, entered, release, closed|
      8.times { entered.pop }
      8.times { release << true }
      assert_raises(Interrupted) { worker.value }
      assert_equal 8, closed.size
    end
  end

  def test_stopping_the_caller_closes_connections_without_starting_queued_requests
    batch(count: 16) do |worker, entered, _release, closed|
      8.times { entered.pop }
      worker.kill.join
      assert_equal 8, closed.size
      assert entered.empty?
    end
  end
end
