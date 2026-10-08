# frozen_string_literal: true

require "timeout"
require_relative "alignment_verification"

class AnalyticsVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks, @received = [], Queue.new
    @time = 0.0
  end

  def call
    MotionPreference.set(@app, reduced: true)
    get(:ticker).remove
    settle
    original = get(:analytics)
    check("Automation cannot send production analytics", original.instance_variable_get(:@environment) == "development")
    original.close
    @analytics = Aljam3::Analytics.new(directory: Aljam3.data_directory, clock: -> { @time },
      wall_clock: -> { Time.utc(2026, 10, 7) + @time }, transport: ->(batch) { @received << batch; :sent })
    @app.instance_variable_set(:@analytics, @analytics)
    seed
    signal("window_focus", true)
    advance(8)
    @app.open_book(@book)
    settle
    check("Loaded text reader counts as reading", @app.analytics_reading?)
    signal("window_activity", true)
    advance(12)
    @app.open_settings
    @app.tick
    check("Settings pause reading time", !@app.analytics_reading?)
    advance(7)
    @automation.wait_frames
    layout = @automation.layout
    check("Settings explain usage collection", layout.any? { |node| node[:text] == "إحصاءات الاستخدام" })
    check("Analytics are always enabled without a toggle", @analytics.enabled? && layout.none? { |node| node[:kind] == "Check" })
    @automation.snapshot(File.join(@output, "settings.png"), scale: 1)
    @app.close_dialog
    @app.tick
    signal("window_focus", false)
    advance(20)
    signal("window_focus", true)
    advance(183)
    signal("window_activity", true)
    advance(4)
    signal("window_focus", false)
    settle
    @app.navigate(:home)
    settle
    query = "عبارة بحث خاصة لا ينبغي إرسالها"
    get(:query_field).text = query
    # Both native submission paths must have identical accounting.
    get(:query_field).focus
    @automation.key("enter")
    settle
    click(action("بحث"))
    settle
    @app.request_catalog(page: 2)
    settle
    signal("window_focus", false)
    settle
    verify_diagnostics
    @analytics.close
    rows = []
    rows.concat(@received.pop) until @received.empty?
    usage = rows.select { |row| row["event"] == "app_usage" }.map { |row| row.fetch("properties") }
    check("Foreground, modal, background, and idle time stay separate", usage.sum { |row| row["active_seconds"] } == 211 && usage.sum { |row| row["reading_seconds"] } == 196)
    check("Opening a book records one count", usage.sum { |row| row["books_opened"] } == 1)
    check("Enter and button each count once; pagination does not", usage.sum { |row| row["title_searches"] } == 2)
    payload = JSON.generate(rows)
    check("Search text and book titles never enter payloads", !payload.include?(query) && !payload.include?(@book.fetch("title")))
    check("Session start and end reach the background sender", rows.count { |row| row["event"] == "app_session_started" } == 1 && rows.count { |row| row["event"] == "app_session_ended" } == 1)
    errors = rows.select { |row| row["event"] == "$exception" }.map { |row| row.fetch("properties") }
    download_errors = errors.select { |row| row["operation"] == "download" }
    check("Failed downloads and retries include HTTP status and attempt", download_errors.map { |row| row["attempt"] } == [1, 2] && download_errors.all? { |row| row["http_status"] == 503 && row["stage"] == "pdf" })
    check("PDF worker failures reach Error Tracking", errors.any? { |row| row["operation"] == "pdf" && row["$exception_message"] == "Unable to read this PDF page." })
    check("Native handler failures are reported as unhandled", errors.any? { |row| row["during"] == "handler" && row.dig("$exception_list", 0, "mechanism", "handled") == false })
    check("Error reports include activity context", errors.all? { |row| row["breadcrumbs"].any? && row["$session_id"] })
    check("Private error messages and titles are removed", !payload.include?("diagnostic-private-title"))
    { passed: true, checks: @checks }
  end

  private

  def verify_diagnostics
    @app.navigate(:downloads)
    downloader = get(:downloader)
    original = downloader.method(:call)
    downloader.define_singleton_method(:call) do |id, **|
      error = Aljam3::ResponseError.new(503)
      Aljam3::Diagnostics.annotate(error, stage: :pdf, book_id: id)
      raise error
    end
    book = @book.merge("id" => 909_090, "title" => "diagnostic-private-title")
    2.times do
      @app.queue_download(book)
      Timeout.timeout(10) do
        until get(:download_queue).entry(book.fetch("id"))&.dig(:status) == :failed
          @app.tick
          @automation.wait_frames
          sleep 0.005
        end
      end
    end
    get(:render_worker).submit(-> { raise "Unable to read this PDF page." }) do |_result, error|
      check("Diagnostics preserve normal worker callbacks", error.is_a?(RuntimeError))
    end
    Shoes::DisplayService.display_service.guarded("diagnostics verification", during: "handler") do
      raise NoMethodError, "undefined method 'diagnostic_probe' for diagnostic-private-title"
    end
    settle
  ensure
    downloader&.define_singleton_method(:call, original) if original
  end

  def get(name) = @app.instance_variable_get("@#{name}")
  def action(key) = get(:action_views).fetch(key)
  def click(control) = @automation.click({ id: control.linkable_id })
  def check(name, condition)
    raise name unless condition

    @checks << name
  end

  def signal(name, active)
    Shoes::DisplayService.display_service.receive("t" => "event", "name" => name, "target" => @app.linkable_id, "args" => [active])
  end

  def advance(seconds)
    seconds.times { @time += 1; @app.tick }
  end

  def settle
    Timeout.timeout(10) do
      loop do
        @app.tick
        @automation.wait_frames
        pending = get(:workers).any?(&:busy?) || get(:storage_worker).busy? || get(:analytics).instance_variable_get(:@worker).busy?
        break unless pending

        sleep 0.005
      end
    end
  end

  def seed
    store = get(:store)
    AlignmentVerification.seed(store)
    @book = AlignmentVerification::BOOKS.first
    store.save_reading(@book.fetch("id"), file_id: @book.fetch("id"), number: 1)
    store.save_preference("reader", { "mode" => "text" })
    @app.instance_variable_set(:@downloaded_ids, store.downloaded_ids)
    @app.draw_window
  end
end
