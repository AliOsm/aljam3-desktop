# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class CategoryDownloadsTest < StoreTestCase
  CATEGORY = { "id" => 2, "name" => "علوم" }.freeze

  class Transfer
    attr_accessor :failures, :cancel_error
    attr_reader :started, :cancelled

    def initialize(store)
      @store, @permits, @started, @cancelled, @failures = store, Queue.new, [], [], []
    end

    def call(id, check:)
      @started << id
      yield 0.4, "PDF", 40, 100
      loop do
        check.call
        raise Aljam3::ConnectionError, "fixture failure" if @failures.include?(id)
        break unless @permits.empty?

        sleep 0.001
      end
      @permits.pop
      @store.complete_download(id, bytes: 100)
    end

    def finish(count = 1) = count.times { @permits << true }
    def repair_download_sizes(after: 0) = nil
    def cancel(id)
      raise @cancel_error if @cancel_error

      @cancelled << id
    end
  end

  def setup
    super
    @books = (1..8).map { |id| book(id) }
    @store.cache_books(@books)
    @transfer = Transfer.new(@store)
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer)
  end

  def teardown
    @queue.close
    super
  end

  def pump_until
    Timeout.timeout(5) do
      loop do
        @queue.tick
        break if yield

        sleep 0.001
      end
    end
  end

  def group = @store.category_downloads.first

  def restart
    @queue.close
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer)
  end

  def test_preview_and_enqueue_skip_completed_and_independently_queued_books
    @store.complete_download(1)
    @queue.enqueue(book(2))
    assert_equal({ total: 8, done: 1, existing: 1, new: 6 }, @store.category_download_preview(2, (1..8).to_a))
    assert_equal 6, @queue.enqueue_category(CATEGORY, (1..8).to_a)
    assert_equal 0, @queue.enqueue_category(CATEGORY, (1..8).to_a)
    assert_equal [1, 2], @store.downloads(ungrouped: true).keys.sort
    assert_equal (3..8).to_a, @store.downloads(category_id: 2).keys
    assert_equal 6, group[:total]
    assert_equal 6, group[:queued]
    @queue.pause_category(2)
    assert_equal :queued, @queue.entry(2)[:status]
    assert_equal 6, group[:paused]
  end

  def test_concurrent_starts_claim_each_book_once_and_never_take_another_groups_members
    results = 2.times.map { Thread.new { @queue.enqueue_category(CATEGORY, (1..8).to_a) } }.map(&:value)
    assert_equal [0, 8], results.sort
    assert_equal 8, @store.download_count
    @queue.pause_category(2)
    other = { "id" => 3, "name" => "تصنيف آخر" }
    assert_equal 0, @queue.enqueue_category(other, (1..8).to_a)
    assert_equal 1, @store.category_downloads.length
    assert_equal 8, @store.category_download_preview(3, (1..8).to_a)[:existing]
  end

  def test_download_filters_include_matching_books_inside_a_partly_finished_category
    @queue.enqueue_category(CATEGORY, [1, 2, 3])
    @queue.pause_category(2)
    @store.complete_download(1)
    assert_equal [2], @store.category_downloads(filter: :done).map { |item| item[:category_id] }
    assert_equal [2], @store.category_downloads(filter: :active).map { |item| item[:category_id] }
    assert_equal [1], @store.downloads(category_id: 2, filter: :done).keys
    assert_equal [2, 3], @store.downloads(category_id: 2, filter: :active).keys
  end

  def test_pause_restart_resume_and_failure_only_retry_preserve_successful_books
    @queue.enqueue_category(CATEGORY, (1..8).to_a)
    @transfer.finish
    pump_until { @queue.current&.dig(:book, "id") == 2 && @queue.current[:bytes] }
    @queue.pause_category(2)
    pump_until { group[:paused] == 7 }
    restart
    assert_equal 7, group[:paused]
    assert_equal 1, group[:done]
    assert_equal 40, @queue.entry(2)[:bytes]
    @transfer.failures = [3]
    @queue.resume_category(CATEGORY)
    @transfer.finish(6)
    pump_until { group[:done] == 7 && group[:failed] == 1 }
    assert_equal 1, @transfer.started.count(1)
    @transfer.failures = []
    @queue.resume_category(CATEGORY, failed_only: true)
    @transfer.finish
    pump_until { group[:done] == 8 }
    assert_equal 1, @transfer.started.count(4)
    assert_equal 2, @transfer.started.count(3)
    assert_empty @store.category_downloads(filter: :active)
    assert_equal 1, @store.category_downloads(filter: :done).length
  end

  def test_cancel_preserves_completed_books_and_independent_downloads_and_survives_restart
    @queue.enqueue(book(8))
    @queue.pause(8)
    @queue.enqueue_category(CATEGORY, (1..7).to_a)
    @transfer.finish
    pump_until { @queue.current&.dig(:book, "id") == 2 && @queue.current[:bytes] }
    @queue.cancel_category(2)
    restart
    pump_until { group[:cancelled] == 6 }
    assert @store.downloaded?(1)
    assert_equal :paused, @queue.entry(8)[:status]
    assert_equal (2..7).to_a, @transfer.cancelled.sort
    assert_equal 0, group[:queued]
    assert_nil @queue.current
    assert_equal :cancelled, @store.downloads(category_id: 2).fetch(2)[:status]
    @queue.resume_category(CATEGORY)
    @transfer.finish(6)
    pump_until { group[:done] == 7 }
    assert_equal 1, @transfer.started.count(1)
  end

  def test_an_active_category_resumes_after_restart_without_replaying_finished_books
    @queue.enqueue_category(CATEGORY, [1, 2])
    @transfer.finish
    pump_until { @queue.current&.dig(:book, "id") == 2 && @queue.current[:bytes] }
    restart
    assert_equal 1, group[:queued]
    @transfer.finish
    pump_until { group[:done] == 2 }
    assert_equal 1, @transfer.started.count(1)
  end

  def test_crash_recovery_honors_bulk_controls_before_the_active_worker_has_stopped
    @queue.enqueue_category(CATEGORY, [1, 2, 3])
    pump_until { @queue.current&.fetch(:bytes, nil) }
    @store.pause_category_download(2)
    @store.recover_downloads
    assert_equal 3, group[:paused]
    assert_nil @store.next_download
    @store.cancel_category_download(2)
    @store.recover_downloads
    assert_equal [1, 2, 3], @store.cancelling_downloads
    assert_nil @store.next_download
  end

  def test_failed_cancellation_retries_cleanup_without_starting_a_download
    @queue.enqueue_category(CATEGORY, [1, 2])
    @transfer.cancel_error = Errno::EACCES.new
    @queue.cancel_category(2)
    pump_until { group[:failed] == 2 }
    assert_empty @transfer.started
    @transfer.cancel_error = nil
    @queue.resume_category(CATEGORY, failed_only: true)
    pump_until { group[:cancelled] == 2 }
    assert_empty @transfer.started
    assert_equal [1, 2], @transfer.cancelled
  end

  def test_repeating_a_category_adds_only_missing_and_new_books
    @queue.enqueue_category(CATEGORY, [1, 2])
    @transfer.finish(2)
    pump_until { group[:done] == 2 }
    assert_equal 1, @queue.enqueue_category(CATEGORY, [1, 2, 3])
    assert_equal 3, group[:total]
    @transfer.finish
    pump_until { group[:done] == 3 }
    assert_equal [1, 2, 3], @transfer.started
  end

  def test_large_categories_are_claimed_atomically_and_book_details_are_paginated
    books = (10..2019).map { |id| book(id) }
    @store.cache_books(books)
    @queue.enqueue_category(CATEGORY, books.map { |item| item.fetch("id") })
    assert_equal 2_010, group[:total]
    assert_equal 12, @store.downloads(category_id: 2).length
    assert_equal 6, @store.downloads(category_id: 2, page: 168).length
    assert_empty @store.downloads(ungrouped: true)
    @queue.pause_category(2)
    restart
    assert_equal 2_010, group[:paused]
    assert_nil @store.next_download
  end

  def test_category_preview_requires_a_complete_listing_and_can_be_cancelled
    books = @books
    api = Object.new
    api.define_singleton_method(:each_category_book_batch) do |_id, check:, &progress|
      books.each_slice(3) { |batch| check.call; progress.call(batch, books.length) }
    end
    library = Aljam3::Library.new(api:, store: @store)
    progress = []
    assert_equal 8, library.category_download_preview(2) { |count, _total| progress << count }[:new]
    assert_equal [3, 6, 8], progress
    assert_empty @store.downloads
    assert_raises(Aljam3::DownloadStopped) { library.category_download_preview(2, check: -> { raise Aljam3::DownloadStopped }) }
    incomplete = Object.new
    incomplete.define_singleton_method(:each_category_book_batch) { |_id, **_options, &block| block.call(books.first(3), 8) }
    library = Aljam3::Library.new(api: incomplete, store: @store)
    assert_raises(Aljam3::ConnectionError) { library.category_download_preview(2) }
    assert_empty @store.category_downloads
    assert_empty @store.downloads
  end

  def test_version_four_upgrade_keeps_downloads_reading_history_and_paused_work
    install_book(1)
    @store.save_reading(1, file_id: 10, number: 2)
    @queue.enqueue(book(2))
    @queue.pause(2)
    @queue.close
    @store.close
    path = File.join(@directory, "library.sqlite3")
    SQLite3::Database.new(path) do |db|
      db.execute_batch("DROP TABLE category_download_books; DROP TABLE category_downloads; PRAGMA user_version = 4;")
    end
    @store = Aljam3::Store.new(path)
    @transfer = Transfer.new(@store)
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer)
    assert @store.downloaded?(1)
    assert_equal 2, @store.recent_books.first.fetch("number")
    assert_equal :paused, @queue.entry(2)[:status]
    assert_equal 2, @store.search("العلم").fetch("pages").length
    assert_empty @store.category_downloads
    assert_equal 1, @queue.enqueue_category(CATEGORY, [2])
  end
end
