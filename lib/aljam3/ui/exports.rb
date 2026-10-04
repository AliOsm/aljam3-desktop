# frozen_string_literal: true

require_relative "../desktop"

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
        @export_download_button = action("", icon: "download", width: 1.0, live: "polite") { queue_download(book) }
        @export_download_progress = progress(top: 41, width: 1.0, height: 4)
        update_export_download
        @export_feedback = para "احفظ نسخة بصيغة PDF أو نص أو Word.", top: 48, size: 14, stroke: muted, live: "polite", wrap: "trim"
        @export_controls = {}
        files = @reader.fetch(:files)
        scroll_area(top: 76, height: @content_height - 76, scroll: true, bottom_padding: 0) do
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

      def export_file(file, format)
        key = [file.fetch("id"), format]
        return if @file_operations.dig(key, :status) == :saving

        path = ask_save_file
        return if !path || path.empty?

        save_file(key, path:, book_id: @reader.fetch(:book).fetch("id")) do
          HTTP.new.download(file.fetch("urls").fetch(format), path, validate_pdf: format == "pdf")
        end
      end

      def save_page_image
        path = ask_save_file
        return if !path || path.empty?

        source = @reader.fetch(:image).path
        save_file([:image, path], path:, book_id: @reader.fetch(:book).fetch("id")) { FileUtils.cp(source, path) }
      end

      def save_file(key, path:, book_id:, &work)
        return if @file_operations.dig(key, :status) == :saving

        job = { key:, path:, book_id:, work: }
        @file_operations.delete(key)
        @file_operations[key] = job
        run_file_save(job)
      end

      def run_file_save(job)
        return if job[:status] == :saving

        job.merge!(status: :saving, message: "جارٍ حفظ الملف…")
        if (failure = @notifications.find(:export_failed))
          notify_file_failure(failure.fetch(:jobs).reject { |item| item.fetch(:key) == job.fetch(:key) })
        end
        update_export_feedback
        @export_worker.submit(job.fetch(:work)) do |_result, error|
          job.merge!(status: error ? :failed : :done, message: error ? error_message(error) : "تم حفظ الملف")
          update_export_feedback
          notify_file_save(job, error:)
          completed = @file_operations.select { |_key, item| item[:status] == :done }.keys
          completed.take([completed.length - 20, 0].max).each { |key| @file_operations.delete(key) }
        end
      end

      def update_export_feedback
        update_activity
        return unless @dialog&.dig(:type) == :export

        jobs = @file_operations.values.select { |job| job[:book_id] == @reader.fetch(:book).fetch("id") }
        latest = jobs.reverse.find { |job| job[:status] == :saving } || jobs.reverse.find { |job| job[:status] == :failed } || jobs.last
        if latest
          @export_feedback.text = latest.fetch(:message)
          @export_feedback.tooltip = "#{latest.fetch(:message)} · #{latest.fetch(:path)}"
          @export_feedback.stroke = latest[:status] == :failed ? primary : muted
        end
        jobs.each do |job|
          next unless (control = @export_controls[job.fetch(:key)])

          control.style(state: job[:status] == :saving ? "disabled" : nil, tooltip: job.fetch(:message))
        end
      end

      def notify_file_save(job, error:)
        if error
          jobs = [*@notifications.find(:export_failed)&.fetch(:jobs, []), job]
          return notify_file_failure(jobs.uniq { |item| item.fetch(:key) })
        end
        @notifications.push(:export_done) do |count|
          { message: count == 1 ? "تم حفظ الملف" : "تم حفظ #{count} ملفات",
            detail: "#{count > 1 ? 'آخر ملف: ' : ''}#{File.basename(job.fetch(:path))}",
            action_label: count == 1 ? "فتح المجلد" : "مجلد آخر ملف",
            action: -> { reveal_saved_file(job.fetch(:path)) } }
        end
      end

      def notify_file_failure(jobs)
        return @notifications.dismiss(:export_failed) if jobs.empty?

        @notifications.push(:export_failed, persistent: true) do
          { error: true, count: jobs.length, jobs:, message: jobs.length == 1 ? "تعذّر حفظ الملف" : "تعذّر حفظ #{jobs.length} ملفات",
            detail: jobs.last.fetch(:message), action_label: "إعادة المحاولة",
            action: -> { jobs.select { |item| item[:status] == :failed }.each { |item| run_file_save(item) } } }
        end
      end

      def reveal_saved_file(path)
        Desktop.reveal(path)
      rescue SystemCallError => error
        warn error.full_message
        @notifications.push(:reveal_failed, persistent: true) do |_count|
          { error: true, message: "تعذّر فتح المجلد", detail: path,
            action_label: "إعادة المحاولة", action: -> { reveal_saved_file(path) } }
        end
      end
    end
  end
end
