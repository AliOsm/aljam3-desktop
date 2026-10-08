# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/analytics"
require "timeout"

class AnalyticsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("aljam3-analytics-")
    @time = 0.0
    @epoch = Time.utc(2026, 10, 7)
    @received = Queue.new
    @result = :sent
    @attempts = 0
    @transport = lambda do |batch|
      @attempts += 1
      @received << Marshal.load(Marshal.dump(batch))
      @result
    end
    start
  end

  def teardown
    @analytics&.close
    FileUtils.remove_entry(@directory)
  end

  def start(**options)
    @analytics = Aljam3::Analytics.new(directory: @directory, transport: @transport,
      clock: -> { @time }, wall_clock: -> { @epoch + @time }, **options)
  end

  def advance(seconds, reading: true)
    seconds.times do
      @time += 1
      @analytics.tick(reading:)
    end
  end

  def settle
    Timeout.timeout(2) do
      loop do
        @analytics.tick(reading: true)
        break unless @analytics.instance_variable_get(:@worker).busy?

        sleep 0.001
      end
    end
  end

  def events
    rows = []
    rows.concat(@received.pop) until @received.empty?
    rows
  end

  def queued
    database = SQLite3::Database.new(File.join(@directory, "analytics/analytics.sqlite3"))
    database.execute("SELECT payload FROM events ORDER BY rowid").map { |row| JSON.parse(row.first) }
  ensure
    database&.close
  end

  def test_foreground_reading_background_and_idle_time
    @analytics.focus(true, reading: true)
    advance(20)
    @analytics.tick(reading: false)
    advance(10, reading: false)
    @analytics.focus(false)
    advance(10)
    @analytics.focus(true, reading: true)
    advance(185)
    settle
    @analytics.close
    delivered = events
    summary = delivered.find { |event| event["event"] == "app_session_ended" }.fetch("properties")
    assert_in_delta 210, summary.fetch("active_seconds"), 0.001
    assert_in_delta 200, summary.fetch("reading_seconds"), 0.001
    usage = delivered.select { |event| event["event"] == "app_usage" }.map { |event| event.fetch("properties") }
    assert_in_delta 210, usage.sum { |row| row.fetch("active_seconds") }, 0.001
    assert_in_delta 200, usage.sum { |row| row.fetch("reading_seconds") }, 0.001
  end

  def test_sleep_and_a_frozen_event_loop_are_not_reading_time
    @analytics.focus(true, reading: true)
    advance(5)
    @time += 3_600
    @analytics.tick(reading: true)
    advance(10)
    @analytics.activity(focused: true, reading: true)
    advance(7)
    settle
    @analytics.close
    summary = events.find { |event| event["event"] == "app_session_ended" }.fetch("properties")
    assert_equal 12, summary.fetch("reading_seconds")
  end

  def test_offline_events_survive_restart_with_original_ids_and_timestamps
    @result = :retry
    @analytics.focus(true, reading: true)
    @analytics.count(:title_searches)
    advance(35)
    settle
    @analytics.close
    saved = queued
    assert_equal %w[app_session_started app_usage app_session_ended], saved.map { |row| row["event"] }
    identity = saved.first.fetch("distinct_id")
    events
    @result = :sent
    @time += 86_400
    start
    settle
    resent = events
    saved.each { |event| assert_includes resent, event }
    assert_equal [identity], resent.map { |row| row["distinct_id"] }.uniq
    assert_equal 2, resent.map { |row| row.dig("properties", "$session_id") }.uniq.length
    assert_empty queued
  end

  def test_interrupted_session_recovers_checkpoint_without_double_counting
    @result = :retry
    @analytics.focus(true, reading: true)
    @analytics.count(:downloads_completed)
    advance(35)
    settle
    # Simulate process death: stop the sender and close SQLite without the normal
    # finish hook. The last durable checkpoint must be recovered on next launch.
    @analytics.instance_variable_get(:@worker).close
    @analytics.instance_variable_get(:@db).close
    @analytics = nil
    events
    @result = :sent
    @time += 100
    start
    settle
    recovered = events
    usage = recovered.find { |row| row["event"] == "app_usage" }.fetch("properties")
    assert_equal 30, usage.fetch("reading_seconds")
    assert_equal 1, usage.fetch("downloads_completed")
    summary = recovered.find { |row| row["event"] == "app_session_ended" }.fetch("properties")
    assert_equal "interrupted", summary.fetch("end_reason")
    assert_equal 30, summary.fetch("active_seconds")
    @analytics.close
    start
    settle
    refute events.any? { |row| row["event"] == "app_usage" && row.dig("properties", "downloads_completed") == 1 }
  end

  def test_retries_wait_and_reuse_event_ids
    @result = :retry
    settle
    first = events
    assert_equal 1, @attempts
    advance(29)
    settle
    assert_equal 1, @attempts
    advance(1)
    settle
    assert_equal 2, @attempts
    assert_equal first, events
    advance(59)
    settle
    assert_equal 2, @attempts
    @result = :sent
    advance(1)
    settle
    assert_equal 3, @attempts
    assert_equal first, events
    assert_empty queued
  end

  def test_only_allowlisted_counters_and_fixed_metadata_are_sent
    @analytics.count(:title_searches)
    @analytics.count(:books_opened)
    @analytics.count("private search query")
    @analytics.count("/home/someone/private-book.pdf")
    @analytics.close
    delivered = events
    usage = delivered.find { |row| row["event"] == "app_usage" }.fetch("properties")
    assert_equal 1, usage.fetch("title_searches")
    assert_equal 1, usage.fetch("books_opened")
    assert_equal true, usage.fetch("$geoip_disable")
    assert_nil usage.fetch("$ip")
    assert_equal false, usage.fetch("$process_person_profile")
    allowed = Aljam3::Analytics::COUNTERS + %w[active_seconds reading_seconds $session_id app_version $os environment $process_person_profile $geoip_disable $ip schema_version]
    assert_empty usage.keys - allowed
    refute_includes JSON.generate(delivered), "private"
    assert_match Aljam3::Analytics::UUID, delivered.first.fetch("distinct_id")
  end

  def test_queue_drops_expired_events_and_keeps_a_fixed_upper_bound
    db = @analytics.instance_variable_get(:@db)
    payload = queued.first.fetch("properties")
    db.transaction do
      (Aljam3::Analytics::MAX_EVENTS + 12).times do |index|
        db.execute("INSERT INTO events VALUES (?, ?, ?)", ["test-#{index}", @epoch.to_i, JSON.generate(payload)])
      end
      db.execute("INSERT INTO events VALUES (?, ?, ?)", ["expired", @epoch.to_i - Aljam3::Analytics::MAX_AGE - 1, "{}"])
    end
    @analytics.send(:checkpoint)
    assert_equal Aljam3::Analytics::MAX_EVENTS, db.get_first_value("SELECT count(*) FROM events")
    assert_nil db.get_first_value("SELECT id FROM events WHERE id = 'expired'")
    assert_nil db.get_first_value("SELECT id FROM events WHERE id = 'test-0'")
  end

  def test_quota_limited_events_are_not_retried_in_a_loop
    @result = :limited
    settle
    assert_equal 1, @attempts
    assert_empty queued
    @analytics.count(:books_opened)
    advance(300)
    settle
    assert_equal 1, @attempts
    assert_equal 1, queued.length
  end

  def test_close_has_a_strict_network_wait_budget
    @analytics.close
    start(transport: ->(_batch) { sleep 5; :sent })
    @analytics.focus(true, reading: true)
    advance(2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @analytics.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.6
    assert queued.any? { |row| row["event"] == "app_session_ended" }
  end

  def test_development_events_never_share_the_production_queue
    @result = :retry
    @analytics.close
    before = queued
    start(environment: "development")
    @analytics.close
    assert_equal before, queued
  end

  def test_corrupt_analytics_storage_does_not_break_the_app
    @analytics.close
    File.binwrite(File.join(@directory, "analytics/analytics.sqlite3"), "broken")
    _out, err = capture_io { start }
    refute @analytics.available?
    assert_includes err, "Analytics unavailable"
    @analytics.focus(true, reading: true)
    @analytics.count(:books_opened)
    @analytics.tick(reading: true)
    @analytics.close
  end

  class HTTPConnection
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :sent

    def initialize(response) = @response = response
    def request(message)
      @sent = message
      yield @response
      # Net::HTTP returns its response, not the value of the response block.
      @response
    end
  end

  def response(code, body)
    result = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new("1.1", code, "test")
    result.define_singleton_method(:read_body) { |&block| block.call(body) }
    result
  end

  def request_result(code, body)
    connection = HTTPConnection.new(response(code, body))
    result = Net::HTTP.stub(:new, connection) { @analytics.send(:request, [{ "event" => "test" }]) }
    [result, connection]
  end

  def test_transport_uses_the_us_https_batch_endpoint_and_bounded_timeouts
    result, connection = request_result("200", '{"status":1}')
    assert_equal :sent, result
    assert_equal "/batch/", connection.sent.path
    assert_equal "us.i.posthog.com", connection.sent["host"]
    assert_equal true, connection.use_ssl
    assert_equal [3, 3, 3, 0], [connection.open_timeout, connection.read_timeout, connection.write_timeout, connection.max_retries]
    payload = JSON.parse(connection.sent.body)
    assert_equal Aljam3::Analytics::PROJECT_TOKEN, payload.fetch("api_key")
    assert_equal [{ "event" => "test" }], payload.fetch("batch")
  end

  def test_transport_distinguishes_quota_bad_requests_and_transient_errors
    assert_equal :limited, request_result("200", '{"status":1,"quota_limited":["events"]}').first
    assert_equal :invalid, request_result("200", '{"status":0}').first
    assert_equal :invalid, request_result("400", "bad request").first
    assert_equal :invalid, request_result("302", "redirect").first
    assert_equal :retry, request_result("429", "retry later").first
    assert_equal :retry, request_result("503", "unavailable").first
    assert_equal :retry, request_result("200", "x" * 65_537).first
  end

  def test_network_exceptions_leave_events_queued_and_the_app_responsive
    @analytics.close
    start(transport: ->(_batch) { raise IOError, "offline" })
    @analytics.focus(true, reading: true)
    advance(3)
    settle
    assert @analytics.available?
    refute_empty queued
  end

  def test_diagnostics_survive_offline_restart_with_session_and_event_time
    @result = :retry
    @time = 7
    error = Aljam3::ResponseError.new(503)
    error.set_backtrace([File.expand_path("../lib/aljam3/downloader.rb", __dir__) + ":42:in 'call'"])
    Aljam3::Diagnostics.annotate(error, stage: :pdf, request_host: "archive.org", book_id: 12)
    @analytics.breadcrumb(:navigation, screen: :downloads)
    @analytics.capture_error(error, operation: :download, context: { attempt: 2 })
    saved = queued.find { |row| row["event"] == "$exception" }
    assert_equal (@epoch + 7).iso8601(3), saved.fetch("timestamp")
    properties = saved.fetch("properties")
    assert_equal 503, properties.fetch("http_status")
    assert_equal "pdf", properties.fetch("stage")
    assert_equal Aljam3::VERSION, properties.fetch("app_version")
    assert_equal true, properties.fetch("$geoip_disable")
    assert_nil properties.fetch("$ip")
    assert_match Aljam3::Analytics::UUID, properties.fetch("$session_id")
    @analytics.close
    events
    @result = :sent
    @time += 100
    start
    settle
    assert_includes events, saved
    refute queued.any? { |row| row["event"] == "$exception" }
  end

  def test_concurrent_background_reports_use_the_durable_queue_on_the_ui_thread
    @result = :retry
    callers = 8.times.map do
      Thread.new do
        8.times { @analytics.capture_error(Aljam3::ResponseError.new(500), operation: :download) }
      end
    end
    callers.each(&:join)
    assert_empty queued.select { |row| row["event"] == "$exception" }
    @analytics.tick
    exceptions = queued.select { |row| row["event"] == "$exception" }
    assert_equal Aljam3::Diagnostics::PER_ERROR, exceptions.length
    @analytics.close
    usage = queued.find { |row| row["event"] == "app_usage" }.fetch("properties")
    assert_equal 64 - Aljam3::Diagnostics::PER_ERROR, usage.fetch("diagnostic_reports_suppressed")
    assert_equal 0, usage.fetch("downloads_failed")
  end

  def test_diagnostic_storage_is_bounded_independently_of_usage_metrics
    @result = :retry
    db = @analytics.instance_variable_get(:@db)
    db.transaction do
      (Aljam3::Analytics::MAX_DIAGNOSTICS + 20).times do |index|
        db.execute("INSERT INTO events VALUES (?, ?, ?)", ["error-#{index}", @epoch.to_i, '{"event":"$exception","properties":{}}'])
      end
    end
    @analytics.send(:checkpoint)
    assert_equal Aljam3::Analytics::MAX_DIAGNOSTICS, queued.count { |row| row["event"] == "$exception" }
    assert_equal 1, queued.count { |row| row["event"] == "app_session_started" }
  end

  def test_development_diagnostics_cannot_leak_into_the_production_queue
    @result = :retry
    @analytics.close
    before = queued
    start(environment: "development")
    @analytics.capture_error(RuntimeError.new("private query"), operation: :ui)
    @analytics.close
    assert_equal before, queued
  end

  def test_pre_diagnostics_sessions_are_recovered_when_upgrading
    @result = :retry
    @analytics.count(:downloads_completed)
    @analytics.send(:checkpoint)
    db = @analytics.instance_variable_get(:@db)
    session = JSON.parse(db.get_first_value("SELECT value FROM preferences WHERE key = 'session'"))
    session.fetch("counts").delete("diagnostic_reports_suppressed")
    db.execute("UPDATE preferences SET value = ? WHERE key = 'session'", [JSON.generate(session)])
    @analytics.instance_variable_get(:@worker).close
    db.close
    @analytics = nil
    start
    assert_equal 1, queued.find { |row| row["event"] == "app_usage" }.dig("properties", "downloads_completed")
  end
end
