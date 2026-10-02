# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui"

class CatalogSearchTest < StoreTestCase
  class View
    include Aljam3::UI
    attr_reader :calls

    def initialize(store)
      @store, @calls = store, []
      @screen, @mode, @query = :saved, :content, "العلم"
      @search_order, @search_scope, @filters = :relevance, :downloaded, { author: 4 }
      @request_number = 0
      @library = self
      @network_worker = self
    end

    def draw_window; end
    def search(query, **options)
      @calls << [query, options]
      Aljam3::Result.new({ "pages" => [] }, :downloaded, nil)
    end
    def submit(work) = yield(work.call, nil)
  end

  def test_search_more_preserves_scope_and_pagination_then_resets_when_scope_changes
    view = View.new(@store)
    view.request_catalog
    assert_equal 10_000, view.calls.last.last.fetch(:pool_size)
    view.request_catalog(expand: true)
    assert_equal 20_000, view.calls.last.last.fetch(:pool_size)
    assert_equal 4, view.calls.last.last.fetch(:author)
    assert view.calls.last.last.fetch(:downloaded)
    view.request_catalog(page: 2)
    assert_equal 20_000, view.calls.last.last.fetch(:pool_size)
    assert_equal 2, view.calls.last.last.fetch(:page)
    view.instance_variable_set(:@filters, { category: 2 })
    view.request_catalog
    assert_equal 10_000, view.calls.last.last.fetch(:pool_size)
    refute view.calls.last.last.key?(:author)
  end
end
