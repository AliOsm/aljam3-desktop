# frozen_string_literal: true

module Aljam3
  module UI
    module DownloadScreen
      def offline_unavailable?(book) = @connection == :offline && !@downloaded_ids.include?(book.fetch("id"))

      def availability_label(book)
        return "متاح دون اتصال" if @downloaded_ids.include?(book.fetch("id"))

        case @download_queue.entry(book.fetch("id"))&.fetch(:status)
        when :queued then "في قائمة التنزيل"
        when :downloading then "قيد التنزيل"
        when :paused, :pausing then "التنزيل متوقف مؤقتًا"
        when :failed then "التنزيل غير مكتمل"
        when :cancelling then "جارٍ إلغاء التنزيل"
        else offline_unavailable?(book) ? "يحتاج إلى اتصال · غير محمّل" : "متاح عبر الإنترنت"
        end
      end

      def format_bytes(bytes)
        return "الحجم غير معروف" unless bytes
        return "#{bytes} بايت" if bytes < 1024
        return "\u2066#{(bytes / 1024.0).round(1)} KB\u2069" if bytes < 1_048_576
        return "\u2066#{(bytes / 1_073_741_824.0).round(2)} GB\u2069" if bytes >= 1_073_741_824

        "\u2066#{(bytes / 1_048_576.0).round(1)} MB\u2069"
      end

      def download_message(download)
        size = download[:bytes] && "#{format_bytes(download[:bytes])}#{download[:total] ? " / #{format_bytes(download[:total])}" : ''}"
        [download.fetch(:message), size].compact.join("  ·  ")
      end

      def draw_downloads
        para "التنزيلات والمساحة", font: HEADING_FONT, size: 24
        pdf_bytes = @store.download_bytes
        storage = ["#{@downloaded_ids.length} كتاب متاح دون اتصال", pdf_bytes && "PDF: #{format_bytes(pdf_bytes)}", "النص والفهرس: #{format_bytes(@store.database_bytes)}"]
        para storage.compact.join(" · "),
          size: 15, stroke: muted, margin_top: 8
        row(top: 72) do
          tabs({ all: "الكل", active: "غير المكتملة", done: "المكتملة" }, selected: @download_filter || :all, width: 288) do |filter|
            @download_filter, @download_page, @results = filter, 1, nil
            draw_window
          end
          stack(width: -634, height: 1)
          action("كتبي المحمّلة", width: 140) { navigate(:saved) }
          @clear_cache_button = action(@clearing_cache ? "جارٍ مسح الصور…" : "مسح الصور المؤقتة", width: 206,
            variant: :ghost, state: @clearing_cache ? "disabled" : nil) { clear_image_cache }
        end
        @storage_feedback_view = para @storage_feedback || "يمكنك إيقاف التنزيل ومتابعته. يُحفظ تقدمك عند إغلاق التطبيق.",
          top: 124, size: 14, stroke: muted, live: "polite"
        @results = scroll_area(top: 164, height: @content_height - 164) do
          page, filter = @download_page || 1, @download_filter || :all
          count = @store.download_count(filter:)
          @download_page = page = [page, [(count.fdiv(Store::PAGE_SIZE)).ceil, 1].max].min
          entries = @download_queue.entries(page:, filter:)
          if entries.empty?
            empty_state("لا توجد تنزيلات هنا", "نزّل الكتاب مرة واحدة لتقرأ النص وPDF وتبحث فيه دون اتصال.",
              icon: "download", action_label: "تصفح الكتب") { navigate(:browse) }
          end
          entries.each do |id, download|
            if download[:status] == :done
              completed_download_row(id, download)
              next
            end
            card(padding: 16) do
                para Text.plain(download.fetch(:book).fetch("title")), size: 20
                label = para download_message(download), size: 14, stroke: muted, margin_top: 8
                bar = progress(width: 1.0, height: 20, margin_top: 12)
                bar.fraction = download.fetch(:fraction)
                @progress_views[id] = { label:, bar: }
                row(height: 48, margin_top: 12) { download_actions(id, download) }
            end
          end
          page_controls(page:, previous: page > 1, following: page * Store::PAGE_SIZE < count) do |number|
            @download_page, @results = number, nil
            draw_window
          end
        end
      end

      def completed_download_row(id, download)
        book = download.fetch(:book)
        card(padding: 16) do
          row(height: 52) do
            stack(width: -312) do
              para text_link(Text.plain(book.fetch("title"))) { open_book(book) }, size: 18, wrap: "trim"
              details = [Text.plain(book.dig("author", "name")), download[:bytes] && format_bytes(download[:bytes]), "متاح دون اتصال"]
              para details.compact.reject(&:empty?).join(" · "),
                size: 13, stroke: muted, margin_top: 8, wrap: "trim"
            end
            row(width: 312) { download_actions(id, download) }
          end
        end
      end

      def download_actions(id, download)
        case download.fetch(:status)
        when :done
          action("قراءة", icon: "book-open", width: 122, margin_left: 12) { open_book(download.fetch(:book)) }
          action("إزالة النسخة المحمّلة", icon: "trash-2", key: [:remove_download, id], width: 180, variant: :ghost) { confirm_remove_download(download.fetch(:book)) }
        when :downloading, :queued
          action("إيقاف مؤقت", icon: "pause", width: 144, margin_left: 12) { @download_queue.pause(id); draw_window }
          action("إلغاء التنزيل", width: 124, variant: :ghost) { cancel_download(id) }
        when :paused, :failed
          action(download[:status] == :paused ? "متابعة التنزيل" : "إعادة المحاولة", icon: "play", width: 158, margin_left: 12) { queue_download(download.fetch(:book)) }
          action("إلغاء التنزيل", width: 124, variant: :ghost) { cancel_download(id) }
        end
      end

      def cancel_download(id)
        @download_queue.cancel(id)
        resolve_download_failure(id)
        refresh_download_state
      end

      def confirm_remove_download(book)
        open_dialog(:remove_download, book:, title: "إزالة النسخة المحمّلة")
      end

      def draw_remove_download
        book = @dialog.fetch(:book)
        bytes = @store.download(book.fetch("id"))&.fetch(:bytes)
        scroll_area(height: @content_height - 48, scroll: true, bottom_padding: 0) do
          para Text.plain(book.fetch("title")), size: 19
          para "سيُحذف PDF والنص المحفوظ. #{bytes ? "حجم ملفات PDF: #{format_bytes(bytes)}. " : ''}تبقى مواضع القراءة والفواصل محفوظة، ويمكنك تنزيل الكتاب مجددًا.",
            size: 16, stroke: muted, margin_top: 12
          para @dialog[:error], size: 14, stroke: primary, margin_top: 12 if @dialog[:error]
        end
        action(@dialog[:busy] ? "جارٍ الإزالة…" : "إزالة النسخة", top: @content_height - 36, right: 0, width: 142,
          variant: :solid, state: @dialog[:busy] ? "disabled" : nil) do
          dialog = @dialog
          dialog[:busy] = true
          draw_window
          @export_worker.submit(-> { @download_queue.remove(book.fetch("id")) }) do |_result, error|
            @downloaded_ids = @store.downloaded_ids unless error
            next unless @dialog.equal?(dialog)

            if error
              @dialog.merge!(busy: false, error: error_message(error))
              draw_window
            else
              close_dialog
              request_catalog if @screen == :saved
              @notifications.push(:removed) do |count|
                { message: count == 1 ? "تمت إزالة النسخة المحمّلة" : "تمت إزالة #{count} نسخ محمّلة",
                  detail: "مواضع القراءة والفواصل محفوظة." }
              end
            end
          end
        end
        action("احتفاظ بالكتاب", top: @content_height - 36, right: 154, width: 144, state: @dialog[:busy] ? "disabled" : nil) { close_dialog }
      end

      def clear_image_cache
        return if @clearing_cache

        @clearing_cache = true
        @clear_cache_button.style(text: "جارٍ مسح الصور…", state: "disabled")
        @render_worker.submit(-> { @pdf.clear_cache }) do |bytes, error|
          @clearing_cache = false
          @storage_feedback = error ? error_message(error) : (bytes.zero? ? "لا توجد صور مؤقتة لحذفها." : "تم تحرير #{format_bytes(bytes)} من الصور المؤقتة.")
          if @screen == :downloads
            @storage_feedback_view.text = @storage_feedback
            @clear_cache_button.style(text: "مسح الصور المؤقتة", state: @dialog ? "disabled" : nil)
          else
            @notifications.push(:cache, persistent: !error.nil?) do |_count|
              { error: !error.nil?, message: @storage_feedback, detail: "ستُنشأ صور الصفحات مجددًا عند القراءة." }
            end
          end
        end
      end
    end
  end
end
