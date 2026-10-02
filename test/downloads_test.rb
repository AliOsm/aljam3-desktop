# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class DownloadsTest < StoreTestCase
  class Transfer
    attr_reader :started, :cancelled
    attr_accessor :error

    def initialize(store)
      @store = store
      @started, @finish = Queue.new, Queue.new
      @cancelled = []
    end

    def call(id, check:)
      @started << id
      yield 0.4, "PDF", 40, 100
      loop do
        check.call
        raise @error if @error
        break unless @finish.empty?

        sleep 0.001
      end
      @finish.pop
      @store.complete_download(id)
    end

    def finish = @finish << true
    def disk_usage(_id) = 100
    def cancel(id) = @cancelled << id
    def remove(id) = @store.discard_download(id)
  end

  def setup
    super
    @transfer = Transfer.new(@store)
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer)
  end

  def teardown
    @queue.close
    super
  end

  def pump_until
    Timeout.timeout(3) do
      loop do
        @queue.tick
        break if yield

        sleep 0.001
      end
    end
  end

  def restart
    @queue.close
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer)
  end

  def test_pause_survives_restart_and_resume_completes
    @queue.enqueue(book)
    pump_until { @queue.entries.dig(1, :bytes) == 40 }
    @queue.pause(1)
    pump_until { @queue.entries.dig(1, :status) == :paused }
    restart
    assert_equal :paused, @queue.entries.fetch(1).fetch(:status)
    assert_equal 40, @queue.entries.fetch(1).fetch(:bytes)
    @queue.enqueue(book)
    @transfer.finish
    pump_until { @queue.entries.dig(1, :status) == :done }
    assert @store.downloaded?(1)
    restart
    assert_equal :done, @queue.entries.fetch(1).fetch(:status)
  end

  def test_shutdown_requeues_active_transfer_and_preserves_queue_order
    @queue.enqueue(book(2))
    @queue.enqueue(book(1))
    pump_until { @queue.entries.dig(2, :bytes) == 40 }
    restart
    assert_equal [2, 1], @queue.entries.keys
    assert_equal :queued, @queue.entries.fetch(2).fetch(:status)
    @transfer.finish
    pump_until { @queue.entries.dig(2, :status) == :done }
    pump_until { @queue.entries.dig(1, :bytes) == 40 }
    assert_equal :downloading, @queue.entries.fetch(1).fetch(:status)
  end

  def test_cancelling_an_active_job_cleans_it_up_before_the_next_job
    @queue.enqueue(book)
    @queue.enqueue(book(2))
    pump_until { @queue.entries.dig(1, :bytes) == 40 }
    @queue.cancel(1)
    pump_until { !@queue.entries.key?(1) }
    assert_equal [1], @transfer.cancelled
    refute @store.downloads.key?(1)
    pump_until { @queue.entries.dig(2, :bytes) == 40 }
  end

  def test_closing_while_a_pause_or_cancel_is_pending_honors_it
    @queue.enqueue(book)
    pump_until { @queue.entries.dig(1, :bytes) == 40 }
    @queue.pause(1)
    restart
    assert_equal :paused, @queue.entries.fetch(1).fetch(:status)
    @queue.enqueue(book)
    @queue.tick
    @queue.cancel(1)
    restart
    assert_empty @queue.entries
    assert_equal [1], @transfer.cancelled
  end

  def test_failed_download_is_durable_and_can_be_retried
    @transfer.error = Aljam3::ConnectionError.new("Offline")
    @queue.enqueue(book)
    pump_until { @queue.entries.dig(1, :status) == :failed }
    restart
    assert_equal :failed, @queue.entries.fetch(1).fetch(:status)
    @transfer.error = nil
    @queue.enqueue(book)
    @transfer.finish
    pump_until { @queue.entries.dig(1, :status) == :done }
    @queue.remove(1)
    refute @store.downloaded?(1)
    assert_empty @store.downloads
  end
end
