# frozen_string_literal: true

module Aljam3
  module UI
    module DownloadScreen
      def offline_unavailable?(book) = @connection == :offline && !@downloaded_ids.include?(book.fetch("id"))

      def availability_label(book)
        return "متاح دون اتصال" if @downloaded_ids.include?(book.fetch("id"))

        case @downloads.dig(book.fetch("id"), :status)
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
        return "#{(bytes / 1_073_741_824.0).round(2)} GB" if bytes >= 1_073_741_824

        "#{(bytes / 1_048_576.0).round(1)} MB"
      end

      def download_message(download)
        size = download[:bytes] && "#{format_bytes(download[:bytes])}#{download[:total] ? " / #{format_bytes(download[:total])}" : ''}"
        [download.fetch(:message), size].compact.join("  ·  ")
      end

      def draw_downloads
        para "التنزيلات والمساحة", font: HEADING_FONT, size: 24
        para "#{@downloaded_ids.length} كتاب متاح دون اتصال · #{format_bytes(@downloader.disk_usage)} من ملفات الكتب.",
          size: 15, stroke: muted, margin_top: 8
        flow(top: 70, width: 1.0, height: 36) do
          action("كتبي المحمّلة", width: 140, margin_right: 12) { navigate(:saved) }
          action("مسح صور الصفحات المؤقتة", width: 206, variant: :ghost) do
            FileUtils.rm_f(Dir.glob(File.join(Aljam3.data_directory, "renders/*.png")))
            @storage_feedback = "تم تحرير مساحة الصور المؤقتة. ستُنشأ مجددًا عند القراءة."
            draw_window
          end
        end
        tabs({ done: "المكتملة", active: "غير المكتملة", all: "الكل" }, selected: @download_filter || :all,
          left: @main_width - 288, top: 70, width: 288) do |filter|
          @download_filter = filter
          @results = nil
          draw_window
        end
        para @storage_feedback || "يمكنك إيقاف التنزيل ومتابعته. يُحفظ تقدمك عند إغلاق التطبيق.", top: 122, size: 14, stroke: muted
        @results = stack(top: 166, width: 1.0, height: @content_height - 166, scroll: !@dialog) do
          entries = @downloads.dup
          @downloaded_ids.each do |id|
            entries[id] ||= { book: @store.book(id), status: :done, fraction: 1, message: "متاح دون اتصال", bytes: @downloader.disk_usage(id) }
          end
          entries.select! { |_, entry| @download_filter == :done ? entry[:status] == :done : entry[:status] != :done } if %i[done active].include?(@download_filter)
          if entries.empty?
            empty_state("لا توجد تنزيلات هنا", "نزّل الكتاب مرة واحدة لتقرأ النص وPDF وتبحث فيه دون اتصال.",
              icon: "download", action_label: "تصفح الكتب") { navigate(:browse) }
          end
          entries.sort_by { |_, entry| entry[:status] == :done ? 1 : 0 }.each do |id, download|
            if download[:status] == :done
              completed_download_row(id, download)
              next
            end
            card do
              stack(margin: 16) do
                book_heading(download.fetch(:book))
                label = para download_message(download), size: 14, stroke: muted, margin_top: 12
                bar = progress(width: 1.0, margin_top: 10)
                bar.fraction = download.fetch(:fraction)
                @progress_views[id] = { label:, bar: }
                flow(height: 52, margin_top: 12) { download_actions(id, download) }
              end
            end
          end
        end
      end

      def completed_download_row(id, download)
        book = download.fetch(:book)
        stack(height: 116, margin_right: 12) do
          para text_link(Text.plain(book.fetch("title"))[0, 100]) { open_book(book) },
            left: 324, top: 16, width: @main_width - 360, size: 18
          para "#{Text.plain(book.dig('author', 'name'))} · #{format_bytes(download[:bytes])} · متاح دون اتصال",
            left: 16, top: 82, width: @main_width - 52, size: 13, stroke: muted
          flow(left: 16, top: 20, width: 300, height: 36) { download_actions(id, download) }
          line 16, 115, @main_width - 28, 115, stroke: line_color
        end
      end

      def download_actions(id, download)
        case download.fetch(:status)
        when :done
          action("قراءة", icon: "book-open", width: 110, margin_right: 8) { open_book(download.fetch(:book)) }
          action("إزالة النسخة المحمّلة", icon: "trash-2", width: 180, variant: :ghost) { confirm_remove_download(download.fetch(:book)) }
        when :downloading, :queued
          action("إيقاف مؤقت", icon: "pause", width: 132, margin_right: 8) { @download_queue.pause(id); draw_window }
          action("إلغاء التنزيل", width: 124, variant: :ghost) { @download_queue.cancel(id); draw_window }
        when :paused, :failed
          action(download[:status] == :paused ? "متابعة التنزيل" : "إعادة المحاولة", icon: "play", width: 146, margin_right: 8) { queue_download(download.fetch(:book)) }
          action("إلغاء التنزيل", width: 124, variant: :ghost) { @download_queue.cancel(id); draw_window }
        end
      end

      def confirm_remove_download(book)
        open_dialog(:remove_download, book:, title: "إزالة النسخة المحمّلة")
      end

      def draw_remove_download
        book = @dialog.fetch(:book)
        para Text.plain(book.fetch("title")), size: 19
        para "سيُحذف PDF والنص المحفوظ لتحرير #{format_bytes(@downloader.disk_usage(book.fetch('id')))}. تبقى مواضع القراءة والفواصل محفوظة، ويمكنك تنزيل الكتاب مجددًا.",
          size: 16, stroke: muted, margin_top: 16
        para @dialog[:error].to_s, size: 14, stroke: primary, margin_top: 12
        action("إزالة النسخة", top: @content_height - 48, width: 142, variant: :solid) do
          begin
            @download_queue.remove(book.fetch("id"))
            @downloaded_ids = @store.downloaded_ids
            close_dialog
            request_catalog if @screen == :saved
          rescue StandardError => error
            @dialog[:error] = error_message(error)
            draw_window
          end
        end
        action("احتفاظ بالكتاب", top: @content_height - 48, left: 154, width: 144) { close_dialog }
      end
    end
  end
end
