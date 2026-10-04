# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/dialogs"

class DialogsTest < Minitest::Test
  class View
    include Aljam3::UI::Dialogs
    attr_reader :dialog, :jobs, :queries

    def initialize
      @dialog = { type: :authors, query: "الأول" }
      @jobs, @queries = [], []
      @network_worker = self
      @library = self
    end

    def submit(work, &callback) = @jobs << [work, callback]
    def authors(query:, page:)
      @queries << [query, page]
      query
    end
    def render_dialog; end
    def refresh_dialog; end
  end

  def test_old_author_results_do_not_replace_a_new_search
    view = View.new
    view.request_authors
    old_work, old_reply = view.jobs.shift
    old_result = old_work.call
    view.dialog[:query] = "الثاني"
    view.request_authors
    old_reply.call(old_result, nil)
    assert_nil view.dialog[:result]
    assert view.dialog[:busy]

    work, reply = view.jobs.shift
    reply.call(work.call, nil)
    assert_equal "الثاني", view.dialog[:result]
    refute view.dialog[:busy]
  end

  def test_author_request_keeps_the_submitted_query_while_user_keeps_typing
    view = View.new
    view.request_authors
    view.dialog[:query] = "لم يُرسل بعد"
    work, reply = view.jobs.shift
    reply.call(work.call, nil)

    assert_equal [["الأول", 1]], view.queries
    assert_equal "الأول", view.dialog[:result]
  end

  def test_superseded_and_dismissed_author_searches_skip_the_network
    view = View.new
    view.request_authors
    view.request_authors
    work, reply = view.jobs.shift
    reply.call(work.call, nil)
    assert_empty view.queries
    view.instance_variable_set(:@dialog, nil)
    work, reply = view.jobs.shift
    reply.call(work.call, nil)
    assert_empty view.queries
  end
end
