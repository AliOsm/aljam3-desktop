# frozen_string_literal: true

require "sqlite3"
require "json"
require "securerandom"
require "net/http"
require "time"
require "fileutils"
require_relative "version"
require_relative "worker"

module Aljam3
  # Only named counters and durations cross this boundary. The queue lives beside
  # app settings, independently of the downloadable library and its location.
  class Analytics
    PROJECT_TOKEN = "phc_CJ2yNLkpzVyeQFzenZFongzbgiAfiGkMc4G3QcLKkzxT"
    HOST = "https://us.i.posthog.com"
    IDLE_SECONDS = 180
    SAMPLE_GAP = 5
    CHECKPOINT_SECONDS = 30
    REPORT_SECONDS = 300
    MAX_EVENTS = 2_000
    MAX_AGE = 30 * 86_400
    BATCH_SIZE = 40
    COUNTERS = %w[books_opened title_searches text_searches author_searches book_searches
      downloads_started downloads_completed downloads_failed category_downloads library_moves file_exports].freeze
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    attr_reader :directory

    def initialize(directory:, host: HOST, token: PROJECT_TOKEN, transport: nil,
      clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, wall_clock: -> { Time.now },
      environment: "production", version: VERSION)
      @directory, @clock, @wall_clock = File.join(directory, "analytics"), clock, wall_clock
      @host, @token, @environment, @version = host, token, environment, version
      @transport = transport || method(:request)
      @deliverable = transport || %w[https://us.i.posthog.com https://eu.i.posthog.com].include?(host)
      @focused = @reading = false
      @now = @last_sample = @last_input = @last_checkpoint = @last_report = @clock.call
      @next_delivery, @retry_delay = @now, 30
      @worker = Worker.new
      FileUtils.mkdir_p(@directory)
      filename = environment == "production" ? "analytics.sqlite3" : "analytics-development.sqlite3"
      @db = SQLite3::Database.new(File.join(@directory, filename))
      @db.busy_timeout = 50
      @db.execute_batch("PRAGMA secure_delete = ON;
        CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, payload TEXT NOT NULL);")
      @available = true
      @installation = preference("installation")
      @installation = SecureRandom.uuid unless UUID.match?(@installation.to_s)
      @db.transaction do
        save_preference("installation", @installation)
        restore_session
        start_session
        prune
      end
    rescue StandardError => error
      unavailable(error)
    end

    def available? = !!@available && !@closed
    alias enabled? available?

    def focus(value, reading: false)
      sample
      @focused, @reading = !!value, !!reading
      @last_input = @now if @focused
      if available? && !@focused
        checkpoint(report: true)
        @next_delivery = @now
        deliver
      end
    rescue StandardError => error
      unavailable(error)
    end

    def activity(focused:, reading: false)
      sample
      @focused, @reading = !!focused, !!reading
      @last_input = @now if @focused
    end

    def count(name)
      return unless enabled? && COUNTERS.include?(name.to_s)

      @session["counts"][name.to_s] += 1
    end

    def tick(reading: false)
      return unless available?

      @worker.drain
      sample
      @reading = !!reading
      return unless enabled?

      if @now - @last_report >= REPORT_SECONDS
        checkpoint(report: true)
      elsif @now - @last_checkpoint >= CHECKPOINT_SECONDS
        checkpoint
      end
      deliver
    rescue StandardError => error
      unavailable(error)
    end

    def close
      return if @closed

      if enabled?
        sample
        @db.transaction do
          report_usage
          end_session("closed")
          save_preference("session", nil)
          prune
        end
        # Give short sessions a chance to arrive now, with a strict exit budget.
        # Anything unacknowledged remains durable for the next launch.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.25
        @worker.drain
        @next_delivery = @now
        deliver
        while @worker.busy?
          @worker.drain
          break unless @worker.busy?
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.005
        end
      end
    rescue StandardError => error
      warn "Analytics: #{error.class}"
    ensure
      @closed = true
      @worker&.close
      @db&.close rescue nil
    end

    private

    def sample
      @now = @clock.call
      elapsed = @now - @last_sample
      if enabled? && @focused && elapsed >= 0 && elapsed <= SAMPLE_GAP
        active = [[@now, @last_input + IDLE_SECONDS].min - @last_sample, 0].max
        @session["active_seconds"] += active
        @session["pending_active_seconds"] += active
        if @reading
          @session["reading_seconds"] += active
          @session["pending_reading_seconds"] += active
        end
      elsif elapsed > SAMPLE_GAP
        # A sleeping computer or blocked event loop is not active reading.
        @last_input = @now - IDLE_SECONDS
      end
      @last_sample = @now
      @session["recorded_at"] = @wall_clock.call.to_f if enabled?
    end

    def start_session
      @session = { "id" => SecureRandom.uuid, "started_at" => @wall_clock.call.to_f,
        "recorded_at" => @wall_clock.call.to_f, "active_seconds" => 0.0, "reading_seconds" => 0.0,
        "pending_active_seconds" => 0.0, "pending_reading_seconds" => 0.0,
        "counts" => COUNTERS.to_h { |name| [name, 0] } }
      enqueue("app_session_started", {})
      save_preference("session", @session)
    end

    def restore_session
      saved = preference("session")
      return unless valid_session?(saved) && @wall_clock.call.to_f - saved.fetch("recorded_at") <= MAX_AGE

      @session = saved
      report_usage
      end_session("interrupted")
    end

    def valid_session?(value)
      value.is_a?(Hash) && UUID.match?(value["id"].to_s) &&
        %w[started_at recorded_at active_seconds reading_seconds pending_active_seconds pending_reading_seconds].all? do |key|
          value[key].is_a?(Numeric) && value[key].finite? && value[key] >= 0
        end && value["counts"].is_a?(Hash) && value["counts"].keys.sort == COUNTERS.sort &&
        value["counts"].values.all? { |count| count.is_a?(Integer) && count >= 0 }
    end

    def end_session(reason)
      enqueue("app_session_ended", @session.slice("active_seconds", "reading_seconds").transform_values { |n| n.round(3) }.merge("end_reason" => reason))
    end

    def checkpoint(report: false)
      @db.transaction do
        report_usage if report
        save_preference("session", @session)
        prune
      end
      @last_checkpoint = @now
      @last_report = @now if report
    end

    def report_usage
      counts = @session.fetch("counts")
      active, reading = @session.values_at("pending_active_seconds", "pending_reading_seconds")
      if active.positive? || counts.values.any?(&:positive?)
        enqueue("app_usage", counts.merge("active_seconds" => active.round(3), "reading_seconds" => reading.round(3)))
      end
      @session["pending_active_seconds"] = @session["pending_reading_seconds"] = 0.0
      @session["counts"] = COUNTERS.to_h { |name| [name, 0] }
    end

    def enqueue(name, properties)
      id = SecureRandom.uuid
      recorded = @session.fetch("recorded_at")
      os = RUBY_PLATFORM.include?("darwin") ? "macOS" : Gem.win_platform? ? "Windows" : "Linux"
      data = { "uuid" => id, "event" => name, "distinct_id" => @installation,
        "timestamp" => Time.at(recorded).utc.iso8601(3),
        "properties" => properties.merge("$session_id" => @session.fetch("id"), "app_version" => @version,
          "$os" => os, "environment" => @environment, "$process_person_profile" => false,
          "$geoip_disable" => true, "$ip" => nil, "schema_version" => 1) }
      @db.execute("INSERT INTO events (id, created_at, payload) VALUES (?, ?, ?)", [id, recorded.to_i, JSON.generate(data)])
    end

    def deliver
      return unless @deliverable && @now >= @next_delivery && !@worker.busy?

      prune
      rows = @db.execute("SELECT id, payload FROM events ORDER BY rowid LIMIT ?", [BATCH_SIZE])
      if rows.empty?
        @next_delivery = @now + 30
        return
      end

      ids = rows.map(&:first)
      batch = rows.map { |row| JSON.parse(row.last) }
      @worker.submit(-> { @transport.call(batch) }) do |result, error|
        if !error && %i[sent limited invalid].include?(result)
          @db.transaction do
            ids.each { |id| @db.execute("DELETE FROM events WHERE id = ?", [id]) }
          end
          @retry_delay = 30
          @next_delivery = @clock.call + (result == :sent ? 1 : 3600)
        else
          @next_delivery = @clock.call + @retry_delay
          @retry_delay = [@retry_delay * 2, 3600].min
        end
      end
    end

    def request(batch)
      uri = URI("#{@host}/batch/")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = http.read_timeout = http.write_timeout = 3
      http.max_retries = 0
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json", "User-Agent" => "Aljam3Desktop/#{@version}")
      request.body = JSON.generate(api_key: @token, batch:)
      http.request(request) do |response|
        return :retry if response.code.to_i == 429 || response.code.to_i >= 500
        return :invalid unless response.is_a?(Net::HTTPSuccess)

        body = +""
        response.read_body do |part|
          body << part
          return :retry if body.bytesize > 65_536
        end
        data = JSON.parse(body)
        return :limited if data.is_a?(Hash) && Array(data["quota_limited"]).any?
        return :invalid if data.is_a?(Hash) && (data["status"] == 0 || data.key?("error"))

        return :sent
      end
    end

    def prune
      @db.execute("DELETE FROM events WHERE created_at < ?", [@wall_clock.call.to_i - MAX_AGE])
      @db.execute("DELETE FROM events WHERE rowid NOT IN (SELECT rowid FROM events ORDER BY rowid DESC LIMIT ?)", [MAX_EVENTS])
    end

    def preference(key)
      value = @db.get_first_value("SELECT value FROM preferences WHERE key = ?", [key])
      JSON.parse(value) if value
    end

    def save_preference(key, value)
      @db.execute("INSERT OR REPLACE INTO preferences (key, value) VALUES (?, ?)", [key, JSON.generate(value)])
    end

    def unavailable(error)
      @available = false
      @worker&.close
      warn "Analytics unavailable: #{error.class}"
    end
  end
end
