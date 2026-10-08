# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/diagnostics"
require_relative "../lib/aljam3/pdf"
require_relative "../lib/aljam3/archive_export"
require_relative "../lib/aljam3/storage"

class DiagnosticsTest < Minitest::Test
  def setup
    @time = 0
    @diagnostics = Aljam3::Diagnostics.new(clock: -> { @time }, wall_clock: -> { Time.utc(2026, 10, 8) + @time })
  end

  def error(type = RuntimeError, message = "private book title")
    type.new(message).tap do |failure|
      failure.set_backtrace(["/Users/private person/Aljam3.app/app/lib/aljam3/downloader.rb:23:in 'Aljam3::Downloader#call'",
        "C:\\Users\\private person\\Aljam3\\app\\lib\\aljam3\\worker.rb:18:in 'block in initialize'"])
    end
  end

  def report(failure = error, **options)
    @diagnostics.report(failure, operation: :download, **options)&.fetch("properties")
  end

  def test_posthog_exception_format_and_private_message_and_paths
    @diagnostics.breadcrumb(:navigation, screen: :reader, title: "private book title", query: "secret search")
    @diagnostics.breadcrumb(:worker, operation: :download, status: :started)
    properties = report(error(Errno::ENOSPC, "/Users/private person/secret book.pdf"),
      context: { book_id: 12, file_id: 34, attempt: 2, bytes: 567, title: "private book title", token: "secret" })
    exception = properties.fetch("$exception_list").first
    assert_equal "Errno::ENOSPC", exception.fetch("type")
    assert_equal Errno::ENOSPC.new.message, exception.fetch("value")
    assert_equal true, exception.dig("mechanism", "handled")
    assert_equal "raw", exception.dig("stacktrace", "type")
    assert_equal ["lib/aljam3/worker.rb", "lib/aljam3/downloader.rb"], exception.dig("stacktrace", "frames").map { |frame| frame.fetch("filename") }
    assert exception.dig("stacktrace", "frames").all? { |frame| frame.fetch("in_app") }
    assert_equal 2, properties.fetch("attempt")
    assert_equal 12, properties.fetch("book_id")
    assert_equal 2, properties.fetch("breadcrumbs").length
    %w[private secret /Users C:].each { |value| refute_includes JSON.generate(properties), value }
  end

  def test_unknown_errors_json_sql_and_object_inspections_never_send_content
    failures = [error(RuntimeError, "username password plain unquoted search"),
      error(JSON::ParserError, 'unexpected content {"title":"secret-title"}'),
      error(SQLite3::SQLException, 'no such column: secret-title'),
      error(NoMethodError, "undefined method 'missing' for {title: 'secret-title'}"),
      error(RuntimeError, "bad\xffcontent".b)]
    failures.each do |failure|
      serialized = JSON.generate(report(failure))
      %w[username password unquoted secret-title bad].each { |private_value| refute_includes serialized, private_value }
    end
    assert_equal "Undefined method: missing", report(error(NoMethodError, "undefined method 'missing' for secret-receiver")).fetch("$exception_message")
  end

  def test_http_context_has_no_url_query_or_credentials_and_preserves_root_cause
    failure = begin
      raise Errno::ECONNRESET, "https://user:password@aljam3.com/api/v1/search?q=secret"
    rescue Errno::ECONNRESET
      begin
        raise Aljam3::ConnectionError, "secret response"
      rescue Aljam3::ConnectionError => wrapped
        wrapped
      end
    end
    Aljam3::Diagnostics.annotate(failure, **Aljam3::Diagnostics.request_context("https://user:password@aljam3.com/api/v1/search?q=secret"),
      stage: :text, saved_pages: 500, expected_pages: 650)
    properties = report(failure)
    assert_equal "aljam3.com", properties.fetch("request_host")
    assert_equal "search", properties.fetch("request_kind")
    assert_equal "text", properties.fetch("stage")
    assert_equal 500, properties.fetch("saved_pages")
    assert_equal ["Aljam3::ConnectionError", "Errno::ECONNRESET"], properties.fetch("$exception_list").map { |item| item.fetch("type") }
    assert_equal 0, properties.fetch("$exception_list").last.dig("mechanism", "parent_id")
    %w[password secret user: https://].each { |value| refute_includes JSON.generate(properties), value }
    assert_empty Aljam3::Diagnostics.context(request_host: "aljam3.com.evil.example", query: "secret", file_id: "private-path")
    [nil, "mailto:private@example.org", "not a URL"].each { |url| assert_empty Aljam3::Diagnostics.request_context(url) }
  end

  def test_native_handler_reports_are_unhandled_and_redacted
    payload = { "class" => "NoMethodError", "message" => "undefined method 'render' for secret book",
      "backtrace" => error.backtrace, "path" => "/Users/private", "during" => "handler" }
    properties = report(payload, handled: false, context: { during: payload["during"] })
    assert_equal false, properties.dig("$exception_list", 0, "mechanism", "handled")
    assert_equal "handler", properties.fetch("during")
    assert_equal "Undefined method: render", properties.fetch("$exception_message")
    refute_includes JSON.generate(properties), "secret book"
  end

  def test_pause_navigation_and_export_cancellations_are_not_errors
    [Aljam3::DownloadStopped, Aljam3::PDF::Cancelled, Aljam3::Store::Worker::Cancelled,
      Aljam3::Storage::Cancelled, Aljam3::ArchiveExport::Cancelled].each { |type| assert_nil report(error(type)) }
    assert_equal 0, @diagnostics.take_suppressed
  end

  def test_duplicates_and_error_storms_are_bounded_without_hiding_other_failures
    failure = error
    refute_nil report(failure)
    assert_nil report(failure)
    2.times { refute_nil report }
    50.times { assert_nil report }
    assert_equal 50, @diagnostics.take_suppressed
    assert_equal 0, @diagnostics.take_suppressed
    refute_nil report(error(Errno::EACCES))
    @time += Aljam3::Diagnostics::WINDOW
    refute_nil report
  end

  def test_activity_context_is_bounded_and_never_accepts_arbitrary_log_lines
    100.times { @diagnostics.breadcrumb(:worker, operation: :pdf, status: :completed, path: "private") }
    @diagnostics.breadcrumb("user typed secret", query: "private")
    properties = report(error(RuntimeError, "Unable to open this PDF."))
    assert_equal Aljam3::Diagnostics::MAX_BREADCRUMBS, properties.fetch("breadcrumbs").length
    assert_equal "Unable to open this PDF.", properties.fetch("$exception_message")
    refute_includes JSON.generate(properties), "private"
    assert_operator JSON.generate(properties).bytesize, :<, 16_384
  end

  def test_background_database_errors_retain_original_type_and_stack
    failure = Aljam3::Store::Worker::RemoteError.new("class" => "SQLite3::BusyException", "message" => "database is locked",
      "backtrace" => error.backtrace)
    properties = report(failure)
    assert_equal "SQLite3::BusyException", properties.fetch("$exception_type")
    assert_equal "database is locked", properties.fetch("$exception_message")
    refute_empty properties.dig("$exception_list", 0, "stacktrace", "frames")
  end

  def test_external_updater_log_only_contributes_known_error_codes
    Dir.mktmpdir do |directory|
      log = File.join(directory, "install.log")
      File.write(log, "private path /Users/name/Applications/Aljam3.app Error Domain=SUSparkleErrorDomain Code=1005 secret contents")
      details = Aljam3::Diagnostics.update_context(directory, "move_to_applications")
      assert_equal({ stage: "move_to_applications", helper_error_domain: "SUSparkleErrorDomain", helper_error_code: 1005 }, details)
      File.write(log, "private path C:\\Users\\name: Access is denied (os error 5)")
      details = Aljam3::Diagnostics.update_context(directory, "failed")
      assert_equal "Windows", details.fetch(:helper_error_domain)
      assert_equal 5, details.fetch(:helper_error_code)
      refute_includes JSON.generate(details), "private"
      File.unlink(log)
      assert_equal({ stage: "failed" }, Aljam3::Diagnostics.update_context(directory, "failed"))
    end
  end
end
