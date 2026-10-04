# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/book_search"

class BookSearchTest < StoreTestCase
  class PendingWorker
    attr_reader :jobs
    def initialize = @jobs = []
    def submit(work, &callback) = @jobs << [work, callback]
  end

  class OfflineAPI
    def search(*) = raise(Aljam3::ConnectionError, "Offline")
  end

  class View
    include Aljam3::UI::BookSearch
    attr_reader :book_search, :network_worker

    def initialize(store)
      @store = store
      @library = Aljam3::Library.new(api: OfflineAPI.new, store:)
      @network_worker = PendingWorker.new
      @dialog = {}
      @book_search = { query: "العلم", book_id: 1 }
    end

    def render_dialog; end
    def refresh_dialog; end
    def error_message(error) = error.message
  end

  def test_cancelled_request_cannot_replace_a_new_search_for_the_same_words
    install_book
    view = View.new(@store)
    view.request_book_search
    old_work, old_callback = view.network_worker.jobs.first
    view.request_book_search
    assert_nil old_work.call, "A superseded queued search should not start"
    old_callback.call(nil, Aljam3::Store::Worker::Cancelled.new)
    assert view.book_search.fetch(:busy)
    assert_nil view.book_search[:error]

    work, callback = view.network_worker.jobs.last
    callback.call(work.call, nil)
    refute view.book_search.fetch(:busy)
    assert_equal 2, view.book_search.fetch(:result).data.fetch("pages").length
  end

  def test_expansion_persists_for_pagination_and_resets_for_a_new_query
    install_book
    view = View.new(@store)
    view.request_book_search
    assert_equal 10_000, view.book_search[:pool_size]
    view.request_book_search(expand: true)
    assert_equal 20_000, view.book_search[:pool_size]
    view.request_book_search(page: 2)
    assert_equal 20_000, view.book_search[:pool_size]
    view.book_search[:query] = "العمل"
    view.request_book_search
    assert_equal 10_000, view.book_search[:pool_size]
  end

  def test_finishing_a_search_preserves_the_next_draft_and_its_results_query
    install_book
    view = View.new(@store)
    view.request_book_search
    work, callback = view.network_worker.jobs.last
    view.book_search[:query] = "مسودة البحث التالي"
    callback.call(work.call, nil)
    refute view.book_search[:busy]
    assert_equal "مسودة البحث التالي", view.book_search[:query]
    assert_equal "العلم", view.book_search[:searched_query]
    assert_equal 2, view.book_search[:result].data.fetch("pages").length
  end
end
