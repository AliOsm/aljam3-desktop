# frozen_string_literal: true

require_relative "../desktop"
require_relative "../export_name"
require_relative "../archive_export"
require "tempfile"

module Aljam3
  module UI
    module Exports
      def update_export_download
        download = @download_queue.entry(@reader.fetch(:book).fetch("id"))
        status = download&.fetch(:status)
        busy = %i[queued downloading pausing cancelling].include?(status)
        label = { done: "متاح للقراءة والبحث دون اتصال", queued: "في قائمة التنزيل", downloading: "جارٍ تنزيل الكتاب…",
          pausing: "جارٍ إيقاف التنزيل…", cancelling: "جارٍ إلغاء التنزيل…", paused: "متابعة تنزيل الكتاب", failed: "إعادة محاولة التنزيل" }
          .fetch(status, "تنزيل الكتاب للقراءة دون اتصال")
        @export_download_button.style(text: label, icon: asset_path("icons", status == :done ? "check" : "download"),
          state: status == :done || busy ? "disabled" : nil)
        @export_download_progress.style(hidden: !busy, fraction: download&.fetch(:fraction) || 0)
      end

      def draw_export
        book = @reader.fetch(:book)
        files = @reader.fetch(:files)
        multiple = files.length > 1
        @export_download_button = action("", icon: "download", width: 1.0, live: "polite") { queue_download(book) }
        @export_download_progress = progress(top: 41, width: 1.0, height: 4)
        update_export_download
        @export_feedback_width = @main_width
        @export_feedback = para export_hint, top: 48, size: 14, stroke: muted, live: "polite", wrap: "trim"
        @export_cancel = action("إلغاء", left: 0, top: 46, width: 72, height: 28, size: 13, hidden: true) do
          cancel_archive_export(@export_active_job) if @export_active_job
        end
        @export_progress = progress(top: 76, width: 1.0, height: 4, hidden: true)
        @export_controls = {}
        @export_unavailable = []
        if multiple
          row(top: 88) do
            %w[pdf txt docx].each_with_index do |format, index|
              available = archive_export(format).available?
              margin = index < 2 ? 8 : 0
              key = [:archive, book.fetch("id"), format]
              @export_unavailable << key unless available
              @export_controls[key] = action("تنزيل كل #{format.upcase}", key:,
                width: (@main_width - 16).fdiv(3) + margin, margin_right: margin,
                state: available ? nil : "disabled", tooltip: available ? "حفظ جميع الأجزاء في ملف ZIP" : "هذه الصيغة غير متاحة لجميع الأجزاء") do
                export_all(format)
              end
            end
          end
          separator(top: 136, width: 1.0)
        end
        list_top = multiple ? 148 : 76
        scroll_area(top: list_top, height: @content_height - list_top, scroll: true, bottom_padding: 0) do
          files.each_with_index do |file, index|
            gap = index < files.length - 1 ? 8 : 0
            row(height: 36 + gap, margin_bottom: gap) do
              para file.fetch("name"), width: -234, size: 15, wrap: "trim" if files.length > 1
              %w[pdf txt docx].each_with_index do |format, format_index|
                margin = format_index < 2 ? 8 : 0
                key = [file.fetch("id"), format]
                @export_controls[key] = action(format.upcase,
                  width: files.length == 1 ? (@main_width - 16).fdiv(3) + margin : 78, margin_right: margin,
                  state: file.dig("urls", format).to_s.empty? ? "disabled" : nil) { export_file(file, format) }
              end
            end
          end
        end
        update_export_feedback
      end

      def export_hint
        @reader.fetch(:files).length > 1 ? "احفظ جميع الأجزاء في ZIP أو نزّل كل جزء على حدة." : "احفظ نسخة بصيغة PDF أو نص أو Word."
      end

      def archive_export(format)
        ArchiveExport.new(book: @reader.fetch(:book), files: @reader.fetch(:files).dup, format:, downloader: @downloader)
      end

      def export_all(format)
        return unless @reader.fetch(:files).length > 1

        book_id = @reader.fetch(:book).fetch("id")
        key = [:archive, book_id, format]
        previous = @file_operations[key]
        return if previous&.dig(:status) == :saving
        return run_file_save(previous) if previous&.dig(:status) == :failed

        archive = archive_export(format)
        return unless archive.available?

        path = export_destination("zip", part: format.upcase)
        save_file(key, path:, book_id:, archive:) if path
      end

      def cancel_archive_export(job)
        return unless job[:status] == :saving && job[:archive]

        job.fetch(:archive).cancel
        job[:message] = "جارٍ إلغاء الحفظ…"
        update_export_feedback
      end

      def drain_export_progress
        changed = false
        until !@export_events || @export_events.empty?
          job, attempt, fraction, message = @export_events.pop
          next unless job[:status] == :saving && job[:attempt].equal?(attempt) && !job.fetch(:archive).cancelled?

          job.merge!(fraction:, message:)
          changed = true
        end
        update_export_feedback if changed
      end

      def export_file(file, format)
        key = [file.fetch("id"), format]
        return if @file_operations.dig(key, :status) == :saving

        path = export_destination(format, part: (@reader.fetch(:files).length > 1 ? file["name"] : nil))
        return unless path

        book_id = @reader.fetch(:book).fetch("id")
        source = @downloader.pdf_path(book_id, file.fetch("id")) if format == "pdf"
        save_file(key, path:, book_id:) do
          if source && File.file?(source)
            copy_export(source, path)
          else
            HTTP.new.download(file.fetch("urls").fetch(format), path, validate_pdf: format == "pdf")
          end
        end
      end

      def save_page_image
        image = @reader[:image]
        return unless image

        path = export_destination("png", page: @reader.fetch(:number))
        return unless path

        book_id = @reader.fetch(:book).fetch("id")
        # Keep the original pixels alive across navigation and cache eviction.
        # Compression happens on the export worker, never in the scroll path.
        save_file([:image, path], path:, book_id:) do
          if image.respond_to?(:pixels)
            Tempfile.create([".aljam3-export-", ".png"], File.dirname(path), binmode: true) do |temporary|
              temporary.close
              @pdf.save_bitmap(image, temporary.path)
              File.rename(temporary.path, path)
            end
          else
            copy_export(image.path, path)
          end
        end
      end

      def export_destination(format, **details)
        filename = ExportName.build(Text.plain(@reader.fetch(:book).fetch("title")), format, **details)
        path = ask_save_file(filename:, extensions: [format], directory: @store.preference("export_directory"),
          title: "حفظ الملف", expanded: true)
        return if !path || path.empty?

        @store.save_preference("export_directory", File.dirname(path))
        path
      end

      def save_file(key, path:, book_id:, worker: @export_worker, archive: nil, &work)
        return if @file_operations.dig(key, :status) == :saving

        job = { key:, path:, book_id:, work:, worker:, archive: }
        run_file_save(job)
      end

      def run_file_save(job)
        return if job[:status] == :saving

        @file_operations.delete(job.fetch(:key))
        @file_operations[job.fetch(:key)] = job
        job[:archive]&.reset
        job.merge!(status: :saving, fraction: 0, message: job[:archive] ? "جارٍ تجهيز ZIP…" : "جارٍ حفظ الملف…")
        if (failure = @notifications.find(:export_failed))
          notify_file_failure(failure.fetch(:jobs).reject { |item| item.fetch(:key) == job.fetch(:key) })
        end
        update_export_feedback
        work = job.fetch(:work)
        if job[:archive]
          @export_events ||= Queue.new
          job[:attempt] = attempt = Object.new
          work = -> do
            job.fetch(:archive).call(job.fetch(:path)) do |fraction, message|
              @export_events << [job, attempt, fraction, message]
            end
          end
        end
        job.fetch(:worker).submit(work) do |_result, error|
          cancelled = error.is_a?(ArchiveExport::Cancelled)
          status = cancelled ? :cancelled : error ? :failed : :done
          @analytics&.count(:file_exports) if status == :done
          message = cancelled ? "تم إلغاء الحفظ" : error ? error_message(error) : "تم حفظ الملف"
          job.merge!(status:, message:)
          job.delete(:work) unless error && !cancelled # Completed exports need not retain their page's pixels.
          update_export_feedback
          notify_file_save(job, error:) unless cancelled
          completed = @file_operations.select { |_key, item| %i[done cancelled].include?(item[:status]) }.keys
          completed.take([completed.length - 20, 0].max).each { |key| @file_operations.delete(key) }
        end
      end

      def update_export_feedback
        update_activity
        return unless @dialog&.dig(:type) == :export

        jobs = @file_operations.values.select { |job| job[:book_id] == @reader.fetch(:book).fetch("id") }
        @export_active_job = jobs.find { |job| job[:status] == :saving && job[:archive] }
        latest = @export_active_job || jobs.reverse.find { |job| job[:status] == :saving } || jobs.reverse.find { |job| job[:status] == :failed } || jobs.last
        cancellable = !!@export_active_job
        @export_cancel.style(hidden: !cancellable, state: @export_active_job&.fetch(:archive)&.cancelled? ? "disabled" : nil)
        @export_feedback.style(left: cancellable ? 80 : 0, width: @export_feedback_width - (cancellable ? 80 : 0))
        @export_progress.style(hidden: !cancellable || @reader.fetch(:files).length < 2, fraction: @export_active_job&.fetch(:fraction, 0) || 0)
        if latest
          @export_feedback.text = latest.fetch(:message)
          @export_feedback.tooltip = "#{latest.fetch(:message)} · #{latest.fetch(:path)}"
          @export_feedback.stroke = latest[:status] == :failed ? primary : muted
        end
        jobs.each do |job|
          next unless (control = @export_controls[job.fetch(:key)])
          next if @export_unavailable.include?(job.fetch(:key))

          control.style(state: job[:status] == :saving ? "disabled" : nil, tooltip: job.fetch(:message))
          if job[:archive]
            control.text = "#{job[:status] == :failed ? 'إعادة' : 'تنزيل كل'} #{job.fetch(:archive).format.upcase}"
          end
        end
      end

      def notify_file_save(job, error:)
        if error
          jobs = [*@notifications.find(:export_failed)&.fetch(:jobs, []), job]
          return notify_file_failure(jobs.uniq { |item| item.fetch(:key) })
        end
        @notifications.push(:export_done) do |count|
          { message: count == 1 ? "تم حفظ الملف" : "تم حفظ #{format_number(count)} ملفات",
            detail: "#{count > 1 ? 'آخر ملف: ' : ''}#{File.basename(job.fetch(:path))}",
            action_label: count == 1 ? "فتح المجلد" : "مجلد آخر ملف",
            action: -> { reveal_saved_file(job.fetch(:path)) } }
        end
      end

      def notify_file_failure(jobs)
        return @notifications.dismiss(:export_failed) if jobs.empty?

        @notifications.push(:export_failed, persistent: true) do
          { error: true, count: jobs.length, jobs:, message: jobs.length == 1 ? "تعذّر حفظ الملف" : "تعذّر حفظ #{format_number(jobs.length)} ملفات",
            detail: jobs.last.fetch(:message), action_label: "إعادة المحاولة",
            action: -> { jobs.select { |item| item[:status] == :failed }.each { |item| run_file_save(item) } } }
        end
      end

      def reveal_saved_file(path)
        Desktop.reveal(path)
      rescue SystemCallError => error
        report_error(error, operation: :open_folder)
        warn error.full_message
        @notifications.push(:reveal_failed, persistent: true) do |_count|
          { error: true, message: "تعذّر فتح المجلد", detail: path,
            action_label: "إعادة المحاولة", action: -> { reveal_saved_file(path) } }
        end
      end

      private

      def copy_export(source, destination)
        Tempfile.create([".aljam3-export-", ".tmp"], File.dirname(destination), binmode: true) do |temporary|
          IO.copy_stream(source, temporary)
          temporary.close
          File.rename(temporary.path, destination)
        end
      end
    end
  end
end
