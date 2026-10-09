# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class DownloadsTest < StoreTestCase
  class Transfer
    attr_reader :started, :cancelled
    attr_accessor :error, :cancel_error, :progresses, :errors

    def initialize(store)
      @store = store
      @started, @finish = Queue.new, Queue.new
      @cancelled = []
      @progresses = [[0.4, "PDF", 40, 100]]
    end

    def call(id, check:)
      @started << id
      @progresses.each { |progress| yield(*progress) }
      loop do
        check.call
        raise @errors.shift if @errors&.any?
        raise @error if @error
        break unless @finish.empty?

        sleep 0.001
      end
      @finish.pop
      @store.complete_download(id)
    end

    def finish = @finish << true
    def disk_usage(_id) = 100
    def repair_download_sizes(after: 0) = nil
    def cancel(id)
      raise @cancel_error if @cancel_error

      @cancelled << id
    end
    def remove(id) = @store.discard_download(id)
  end

  def setup
    super
    @transfer = Transfer.new(@store)
    @finished = []
    @queue = Aljam3::Downloads.new(retry_delays: [0, 0], store: @store, downloader: @transfer) { |download| @finished << download }
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
    @queue = Aljam3::Downloads.new(retry_delays: [0, 0], store: @store, downloader: @transfer) { |download| @finished << download }
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

  def test_fast_transfer_progress_does_not_write_the_database_for_every_chunk
    @transfer.progresses = Array.new(1_000) { |index| [0.4, "PDF", index + 1, 2_000] }
    writes = []
    @store.instance_variable_get(:@db).trace { |sql| writes << sql if sql.start_with?("INSERT INTO downloads") }
    @queue.enqueue(book)
    pump_until { @queue.entry(1)[:bytes] == 1_000 }
    assert_operator writes.size, :<, 20
    @queue.pause(1)
    pump_until { @queue.entry(1)[:status] == :paused }
    assert_equal 1_000, @store.download(1).fetch(:bytes)
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

  def test_cancellation_failure_can_be_retried_without_starting_a_transfer
    @queue.enqueue(book)
    @transfer.cancel_error = Errno::EACCES.new("test file is busy")
    @queue.cancel(1)
    pump_until { @queue.entry(1)[:status] == :failed }
    assert_equal "cancel", @finished.last.fetch(:failure)
    assert @transfer.started.empty?
    @transfer.cancel_error = nil
    @queue.cancel(1)
    pump_until { !@queue.entry(1) }
    assert_equal [1], @transfer.cancelled
    assert_equal 1, @finished.length
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
    pump_until { @queue.entries.empty? }
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

  def test_transient_connection_failures_retry_and_announce_only_the_completed_book
    @transfer.errors = [Aljam3::ConnectionError.new("connection reset"), Aljam3::ConnectionError.new("timeout")]
    @queue.enqueue(book)
    @transfer.finish
    pump_until { @finished.any? }
    assert_equal [:done], @finished.map { |entry| entry[:status] }
    assert_equal 3, @transfer.started.size
    assert @store.downloaded?(1)
  end

  def test_exhausted_network_retries_report_once_with_the_retry_count
    errors = []
    @queue.close
    @queue = Aljam3::Downloads.new(retry_delays: [0, 0], store: @store, downloader: @transfer,
      on_error: ->(error, context) { errors << [error, context] })
    @transfer.error = Aljam3::ConnectionError.new("timeout")
    @queue.enqueue(book)
    pump_until { @queue.entry(1)[:status] == :failed }
    assert_equal 3, @transfer.started.size
    assert_equal 1, errors.size
    assert_equal 2, errors.first.first.instance_variable_get(:@aljam3_diagnostics).fetch("retry_count")
    assert_equal 40, @queue.entry(1)[:bytes]
  end

  def test_pause_and_cancel_interrupt_the_retry_delay_without_another_request
    [:pause, :cancel].each do |action|
      @queue.close
      @queue = Aljam3::Downloads.new(retry_delays: [30], store: @store, downloader: @transfer)
      @transfer.error = Aljam3::ConnectionError.new("timeout")
      @queue.enqueue(book)
      pump_until { @queue.current&.dig(:message)&.include?("إعادة المحاولة") }
      starts = @transfer.started.size
      @queue.public_send(action, 1)
      pump_until { action == :cancel ? @queue.entry(1).nil? : @queue.entry(1)[:status] == :paused }
      assert_equal starts, @transfer.started.size
      assert_empty @finished
    end
  end

  def test_shutdown_during_a_retry_preserves_partial_progress_and_resumes_on_restart
    @queue.close
    @queue = Aljam3::Downloads.new(retry_delays: [30], store: @store, downloader: @transfer)
    @transfer.error = Aljam3::ConnectionError.new("timeout")
    @queue.enqueue(book)
    pump_until { @queue.current&.dig(:message)&.include?("إعادة المحاولة") }
    restart
    assert_equal :queued, @queue.entry(1)[:status]
    assert_equal 40, @queue.entry(1)[:bytes]
    @transfer.error = nil
    @transfer.finish
    pump_until { @store.downloaded?(1) }
    assert_equal [:done], @finished.map { |entry| entry[:status] }
  end

  def test_validation_failures_are_not_retried_as_network_outages
    @transfer.error = Aljam3::Diagnostics.annotate(Aljam3::ConnectionError.new("changed page count"), stage: :validate)
    @queue.enqueue(book)
    pump_until { @queue.entry(1)[:status] == :failed }
    assert_equal 1, @transfer.started.size
  end

  def test_a_completed_book_announces_once_and_does_not_replay_after_restart
    assert @queue.enqueue(book)
    refute @queue.enqueue(book)
    @transfer.finish
    pump_until { @store.downloaded?(1) }
    pump_until { @finished.any? }
    assert_equal [:done], @finished.map { |entry| entry[:status] }
    assert_equal 1, @finished.first.dig(:book, "id")
    refute @queue.enqueue(book)
    restart
    @queue.tick
    assert_equal 1, @finished.length
  end

  def test_failures_notify_once_but_pauses_and_progress_stay_quiet
    @queue.enqueue(book)
    pump_until { @queue.current&.fetch(:bytes, nil) == 40 }
    @queue.pause(1)
    pump_until { @queue.entry(1)[:status] == :paused }
    assert_empty @finished
    assert_equal({ paused: 1 }, @store.download_state_counts)
    @transfer.error = Aljam3::ConnectionError.new("Offline")
    @queue.enqueue(book)
    pump_until { @finished.any? }
    assert_equal [:failed], @finished.map { |entry| entry[:status] }
    assert_equal({ failed: 1 }, @store.download_state_counts)
    10.times { @queue.tick }
    assert_equal 1, @finished.length
  end

  def test_failure_reports_preserve_the_exception_attempt_and_progress_but_not_the_book
    @queue.close
    errors = []
    @queue = Aljam3::Downloads.new(retry_delays: [0, 0], store: @store, downloader: @transfer,
      on_error: ->(error, context) { errors << [error, context] })
    @transfer.error = Aljam3::ResponseError.new(503)
    @queue.enqueue(book)
    pump_until { @queue.entry(1)[:status] == :failed }
    assert_same @transfer.error, errors.first.first
    assert_equal 1, errors.first.last.fetch(:attempt)
    assert_equal 1, errors.first.last.fetch(:book_id)
    refute errors.first.last.key?(:book)
    refute_includes JSON.generate(@store.download(1)), "ResponseError"
    @queue.enqueue(book)
    pump_until { errors.length == 2 }
    assert_equal 2, errors.last.last.fetch(:attempt)
    @transfer.error = nil
    @queue.enqueue(book)
    pump_until { @queue.current&.fetch(:bytes, nil) == 40 }
    @queue.pause(1)
    pump_until { @queue.entry(1)[:status] == :paused }
    assert_equal 2, errors.length
  end

  def test_cancel_failures_reach_diagnostics_and_broken_reporting_cannot_break_downloads
    @queue.close
    failures = []
    @queue = Aljam3::Downloads.new(retry_delays: [0, 0], store: @store, downloader: @transfer,
      on_error: ->(error, context) { failures << [error, context]; raise "reporter failure" })
    @transfer.cancel_error = Errno::EACCES.new("private path")
    @queue.enqueue(book)
    @queue.cancel(1)
    _out, err = capture_io { pump_until { @queue.entry(1)[:status] == :failed } }
    assert_includes err, "Download diagnostics: RuntimeError"
    assert_same @transfer.cancel_error, failures.first.first
    assert_equal :download_cancel, failures.first.last.fetch(:operation)
    @transfer.cancel_error = nil
    @queue.cancel(1)
    pump_until { @queue.entry(1).nil? }
  end
end
