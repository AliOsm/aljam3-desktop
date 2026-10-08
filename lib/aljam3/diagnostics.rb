# frozen_string_literal: true

require "digest"
require "time"
require "uri"

module Aljam3
  # Technical context only. Never serialize arbitrary logs, request bodies,
  # exception receivers, SQL, URLs, or user-selected paths into analytics.
  class Diagnostics
    MAX_BREADCRUMBS = 30
    MAX_FRAMES = 30
    WINDOW = 300
    PER_ERROR = 3
    PER_WINDOW = 30
    CANCELLED = %w[Aljam3::DownloadStopped Aljam3::PDF::Cancelled Aljam3::Store::Worker::Cancelled
      Aljam3::Storage::Cancelled Aljam3::ArchiveExport::Cancelled].freeze
    NUMBERS = %w[book_id file_id category_id page_number expected_pages saved_pages bytes total_bytes
      attempt http_status redirects duration_ms errno].freeze
    LABELS = {
      "operation" => %w[startup shutdown process_exit ui network catalog_fallback pdf text export category
        storage update download download_cancel download_cleanup download_repair open_folder cache],
      "stage" => %w[metadata prepare pdf text validate commit cancel cleanup request restore check download install
        startup handler timer exit move_to_applications failed rolled_back checking downloading installing restoring],
      "screen" => %w[home reader opening categories authors browse saved downloads],
      "search_mode" => %w[books content authors], "reader_mode" => %w[text pdf split],
      "connection" => %w[checking online offline unavailable],
      "status" => %w[started completed failed cancelled],
      "request_kind" => %w[books authors categories libraries files search pdf other],
      "source" => %w[online offline local downloaded cached],
      "during" => %w[startup handler timer exit], "format" => %w[pdf txt docx png zip],
      "helper_error_domain" => %w[SUSparkleErrorDomain NSCocoaErrorDomain NSPOSIXErrorDomain NSURLErrorDomain Windows],
      "feature" => %w[books_opened title_searches text_searches author_searches book_searches downloads_started
        downloads_completed downloads_failed category_downloads library_moves file_exports]
    }.freeze
    FLAGS = %w[resumed category_download fallback].freeze
    EVENTS = %w[session navigation dialog connection worker download counter].freeze
    DIALOGS = %w[settings filters book_search export category_download move_library unavailable details].freeze
    SAFE_MESSAGES = [
      "This book has no downloadable files.", "The book's page count changed. Please retry the download.",
      "Download finished without a complete book.", "The update helper failed.",
      "The category changed while preparing its download. Please retry.", "The category listing is incomplete. Please retry.",
      "The download ended before the complete file arrived.", "The download is not a PDF.",
      "The PDF changed. Please retry.", "This host does not support reading PDF sections.",
      "Invalid PDF byte range.", "PDF range exceeded its requested size.", "The PDF section was interrupted.",
      "Invalid partial download response.", "The library returned an invalid response.",
      "The server does not support combined title filters.", "Unexpected category response.", "Category pagination did not advance.",
      "Library database failed its integrity check", "This library was created by a newer version of Aljam3 Desktop.",
      "The library worker stopped unexpectedly.", "Unable to open this PDF.", "Unable to read this PDF page.",
      "This PDF page is too large to display.", "Unable to allocate the PDF page image.", "Incomplete cached image.",
      "This page is unavailable.", "The search page could not be found in this book.", "Read outside PDF.",
      "Invalid byte range.", "Expected an HTTP(S) URL.", "Unknown export format.", "No files to export.",
      "This format is not available for every volume.", "Release metadata is too large", "Invalid release signature",
      "Invalid release version", "Unexpected package URL", "Invalid package size", "Invalid package checksum",
      "Missing Mac update signature", "Package exceeds signed size", "Package checksum mismatch",
      "Downloaded update is no longer valid", "Unsafe update URL", "Too many redirects",
      "تعذّر قراءة إعدادات موقع المكتبة.", "لم يتم العثور على مجلد المكتبة المحدد.",
      "هذا المجلد لا يحتوي على مكتبتك. اختر مجلد المكتبة الأصلي.",
      "هذه المكتبة مفتوحة في نافذة أخرى. أغلقها ثم حاول مجددًا.",
      "اختر مجلدًا آخر خارج مجلد المكتبة الحالي.", "المجلد مستخدم في نافذة أخرى. اختر مجلدًا آخر.",
      "لم يكتمل نقل المكتبة.", "اختر مجلدًا فارغًا لحفظ المكتبة؛ لن ندمجها مع ملفات أخرى.",
      "تعذّر الوصول إلى قاعدة بيانات المكتبة.", "تحتوي المكتبة على رابط ملفات غير مدعوم. لم تُنقل المكتبة.",
      "تغيّرت ملفات المكتبة أثناء النقل. أعد المحاولة.", "تعذّر التحقق من الملفات المنقولة. المكتبة الأصلية محفوظة."
    ].freeze

    def self.context(values)
      values.each_with_object({}) do |(key, value), clean|
        key = key.to_s
        if NUMBERS.include?(key)
          clean[key] = value if value.is_a?(Integer) && value.between?(0, 2**63 - 1)
        elsif key == "helper_error_code"
          clean[key] = value if value.is_a?(Integer) && value.between?(-2**31, 2**31 - 1)
        elsif LABELS.key?(key)
          clean[key] = value.to_s if LABELS.fetch(key).include?(value.to_s)
        elsif FLAGS.include?(key)
          clean[key] = value if value == true || value == false
        elsif key == "request_host"
          host = value.to_s.downcase
          clean[key] = host if host.match?(/\A(?:[a-z0-9-]+\.)*(?:aljam3\.com|archive\.org|github\.com|githubusercontent\.com)\z/)
        elsif key == "dialog"
          clean[key] = value.to_s if DIALOGS.include?(value.to_s)
        end
      end
    end

    def self.annotate(error, **values)
      previous = error.instance_variable_get(:@aljam3_diagnostics) || {}
      error.instance_variable_set(:@aljam3_diagnostics, previous.merge(context(values))) unless error.frozen?
      error
    end

    def self.request_context(url)
      uri = URI(url)
      return {} unless %w[http https].include?(uri.scheme)

      path = uri.path.to_s
      kind = path[%r{\A/api/v1/(books|authors|categories|libraries|files|search)(?:/|\z)}, 1]
      { request_host: uri.host, request_kind: kind || (path.end_with?(".pdf") ? "pdf" : "other") }
    rescue URI::InvalidURIError, ArgumentError, TypeError
      {}
    end

    # The external updater cannot send events while the app is closed. Recover
    # only known platform error codes on next launch, never its raw log text.
    def self.update_context(directory, outcome)
      details = { stage: outcome }
      File.open(File.join(directory, "install.log"), "rb") do |file|
        file.seek([file.size - 16_384, 0].max)
        log = file.read(16_384).force_encoding(Encoding::UTF_8).scrub
        if (match = log.match(/Error Domain=(SUSparkleErrorDomain|NSCocoaErrorDomain|NSPOSIXErrorDomain|NSURLErrorDomain) Code=(-?\d+)/))
          details.merge!(helper_error_domain: match[1], helper_error_code: match[2].to_i)
        elsif (match = log.match(/os error (-?\d+)/))
          details.merge!(helper_error_domain: "Windows", helper_error_code: match[1].to_i)
        end
      end
      details
    rescue SystemCallError, IOError
      details
    end

    def initialize(clock:, wall_clock:)
      @clock, @wall_clock = clock, wall_clock
      @lock, @seen = Mutex.new, ObjectSpace::WeakMap.new
      @breadcrumbs, @groups, @suppressed = [], {}, 0
      @window, @count = @clock.call, 0
    end

    def breadcrumb(event, **values)
      return unless EVENTS.include?(event.to_s)

      @lock.synchronize do
        @breadcrumbs << { "timestamp" => @wall_clock.call.utc.iso8601(3), "event" => event.to_s, **self.class.context(values) }
        @breadcrumbs.shift while @breadcrumbs.length > MAX_BREADCRUMBS
      end
    end

    def report(error, operation:, context: {}, handled: true)
      @lock.synchronize do
        return if !error || CANCELLED.include?(type_of(error)) || @seen.key?(error)

        @seen[error] = true
        details = self.class.context(context.merge(operation:))
        chain, seen, current = [], [], error
        while current && chain.length < 3 && !seen.any? { |item| item.equal?(current) }
          seen << current
          details.merge!(self.class.context(current.instance_variable_get(:@aljam3_diagnostics) || {}))
          details["http_status"] ||= current.status if current.respond_to?(:status) && current.status.is_a?(Integer)
          details["errno"] ||= current.errno if current.is_a?(SystemCallError)
          mechanism = { "type" => "generic", "handled" => handled, "exception_id" => chain.length }
          mechanism.merge!("type" => "chained", "source" => "cause", "parent_id" => chain.length - 1) unless chain.empty?
          chain << { "type" => type_of(current), "value" => message_of(current), "mechanism" => mechanism,
            "stacktrace" => { "type" => "raw", "frames" => frames_of(current) } }
          current = current.respond_to?(:cause) ? current.cause : nil
        end
        fingerprint = Digest::SHA256.hexdigest([details.values_at("operation", "stage", "http_status"),
          chain.map { |item| [item["type"], item["value"], item.dig("stacktrace", "frames").last] }].inspect)
        if @clock.call - @window >= WINDOW
          @window, @count, @groups = @clock.call, 0, {}
        end
        if @count >= PER_WINDOW || @groups.fetch(fingerprint, 0) >= PER_ERROR
          @suppressed += 1
          return
        end
        @count += 1
        @groups[fingerprint] = @groups.fetch(fingerprint, 0) + 1
        { "properties" => details.merge("$exception_list" => chain, "$exception_level" => "error",
            "$exception_type" => chain.first["type"], "$exception_message" => chain.first["value"],
            "breadcrumbs" => @breadcrumbs.map(&:dup), "diagnostic_schema_version" => 1,
            "ruby_version" => RUBY_VERSION, "runtime_platform" => RUBY_PLATFORM),
          "timestamp" => @wall_clock.call.to_f }
      end
    end

    def take_suppressed
      @lock.synchronize { value = @suppressed; @suppressed = 0; value }
    end

    private

    def type_of(error)
      name = error.is_a?(Hash) ? error["class"] : error.respond_to?(:original_error_class) ? error.original_error_class : error.class.name
      name.to_s.match?(/\A[A-Za-z][A-Za-z0-9_:]{0,120}\z/) ? name.to_s : "Error"
    end

    def message_of(error)
      type = type_of(error)
      message = error.is_a?(Hash) ? error["message"].to_s : error.message.to_s
      message = message.byteslice(0, 2048).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      return message if SAFE_MESSAGES.include?(message)
      return message if message.match?(/\A(?:The library returned HTTP [1-5]\d\d\.|Update server returned [1-5]\d\d|Page \d+ is outside this PDF \(\d+ pages\)\.)\z/)
      return "Invalid JSON response" if type == "JSON::ParserError"
      return "Invalid update metadata" if message.start_with?("Invalid update metadata:")
      return "تعذّر قراءة إعدادات موقع المكتبة." if message.start_with?("تعذّر قراءة إعدادات موقع المكتبة:")
      if type.start_with?("Errno::") && Errno.const_defined?(type.delete_prefix("Errno::"), false)
        return Errno.const_get(type.delete_prefix("Errno::")).new.message
      end
      if %w[NoMethodError NameError].include?(type)
        name = message[/\Aundefined (?:method|local variable or method) [`']([a-zA-Z_][a-zA-Z_0-9!?=]*)['`]/, 1]
        return "Undefined method: #{name}" if name
      end
      if type == "KeyError"
        key = message[/\Akey not found: "([a-z_]+)"\z/, 1]
        return "Missing field: #{key}" if %w[id files urls pdf pages pages_count pagination count next_page number content title book file_id].include?(key)
      end
      if type.start_with?("SQLite3::")
        reason = %w[database\ is\ locked database\ disk\ image\ is\ malformed database\ or\ disk\ is\ full
          disk\ I/O\ error unable\ to\ open\ database\ file].find { |value| message.start_with?(value) }
        return reason || "SQLite operation failed"
      end
      return "Network connection failed" if type == "Aljam3::ConnectionError" || type == "SocketError"
      return "Network request timed out" if type.match?(/(?:Timeout|Net::(?:Read|Open|Write)Timeout)/)
      return "TLS connection failed" if type == "OpenSSL::SSL::SSLError"

      # Unknown messages can embed a whole book, query, object inspection, or
      # response body. The type, stack, and allowlisted context remain useful.
      "#{type} (private message omitted)"
    end

    def frames_of(error)
      backtrace = error.is_a?(Hash) ? error["backtrace"] : error.backtrace
      Array(backtrace).first(MAX_FRAMES).filter_map do |line|
        match = line.to_s.byteslice(0, 2048).encode(Encoding::UTF_8, invalid: :replace, undef: :replace).match(/\A(.+?):(\d+)(?::in [`'](.*?)['`])?\z/)
        next unless match

        path = match[1].tr("\\", "/")
        # Keep shipped source paths, never a user's absolute installation path.
        filename = path[%r{(?:\A|/)(lib/aljam3(?:/[^/]+)*\.rb)\z}, 1]
        filename ||= "app.rb" if path.end_with?("/app.rb") || path == "app.rb"
        in_app = !!filename
        filename ||= path[%r{/(?:gems|ruby/lib|scarpe)/(.*\.rb)\z}, 1]
        filename = "[external]" unless filename && filename.length <= 160 && filename.match?(%r{\A[a-zA-Z0-9_./-]+\z})
        function = match[3].to_s
        function = "[unknown]" unless function.match?(/\A[a-zA-Z0-9_ :.!?=#<>\[\]-]{0,160}\z/)
        { "filename" => filename, "lineno" => match[2].to_i, "function" => function,
          "in_app" => in_app, "platform" => "ruby" }
      end.reverse
    end
  end
end
