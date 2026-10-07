# frozen_string_literal: true

module Aljam3
  module UI
    module CategoryDownloadScreen
      def prepare_category_download(category)
        open_dialog(:category_download, category:, busy: true)
        dialog = @dialog
        @category_scan_events ||= Queue.new
        check = -> { raise DownloadStopped unless @dialog.equal?(dialog) }
        @category_worker.submit(-> {
          @library.category_download_preview(category.fetch("id"), check:) do |count, total|
            @category_scan_events << [dialog, count, total]
          end
        }) do |preview, error|
          next unless @dialog.equal?(dialog)

          dialog.merge!(busy: false, preview:, error: error && error_message(error))
          refresh_dialog
        end
      end

      def category_download_dialog_height
        return 232 if @dialog[:error]

        @dialog[:preview] ? 244 : 212
      end

      def draw_category_download
        category, preview = @dialog.values_at(:category, :preview)
        para Text.plain(category.fetch("name")), size: 19, wrap: "trim", tooltip: Text.plain(category.fetch("name"))
        para "جميع كتب التصنيف مع PDF والنص للقراءة والبحث دون اتصال.", top: 32, size: 14, stroke: muted
        label = if @dialog[:error]
          @dialog[:error]
        elsif preview
          "#{format_number(preview[:total])} كتاب · #{format_number(preview[:done])} محمّل · #{format_number(preview[:existing])} في التنزيلات"
        else
          "جارٍ جمع كتب التصنيف…"
        end
        @category_scan_label = para label, top: 64, size: 14, stroke: @dialog[:error] ? primary : muted, live: "polite"
        if preview
          message = preview[:new].positive? ? "سيُنزّل #{format_number(preview[:new])} كتاب." : "كل الكتب محمّلة أو موجودة في التنزيلات."
          para message, top: 88, size: 15
        end
        row(top: @content_height - 36) do
          if @dialog[:error]
            action("إعادة المحاولة", width: 176, margin_right: 12, variant: :solid) { prepare_category_download(category) }
          elsif preview
            if preview[:new].positive?
              action(@dialog[:starting] ? "جارٍ الإضافة…" : "بدء التنزيل", width: 176, margin_right: 12, variant: :solid,
                state: @dialog[:starting] ? "disabled" : nil, key: :start_category_download) { start_category_download }
            else
              action("عرض التنزيلات", width: 176, margin_right: 12, variant: :solid) { navigate(:downloads) }
            end
          else
            action("بدء التنزيل", width: 176, margin_right: 12, variant: :solid, state: "disabled")
          end
          action("إغلاق", width: 88) { close_dialog }
        end
      end

      def start_category_download
        dialog = @dialog
        return if dialog[:starting]

        category, preview = dialog.values_at(:category, :preview)
        dialog[:starting] = true
        refresh_dialog
        @category_worker.submit(-> { @download_queue.enqueue_category(category, preview.fetch(:book_ids)) }) do |_count, error|
          if error
            message = error_message(error)
            if @dialog.equal?(dialog)
              dialog.merge!(starting: false, error: message)
              refresh_dialog
            else
              @notifications.push([:category_download, category.fetch("id")], persistent: true) do
                { error: true, message: "تعذّر بدء تنزيل التصنيف", detail: message,
                  action_label: "إعادة المحاولة", action: -> { prepare_category_download(category) } }
              end
            end
          else
            @analytics&.count(:category_downloads)
            @notifications.dismiss([:category_download, category.fetch("id")])
            refresh_download_state
            if @dialog.equal?(dialog)
              @download_filter, @download_page = :all, 1
              navigate(:downloads)
            end
          end
        end
      end

      def tick_category_downloads
        until !@category_scan_events || @category_scan_events.empty?
          dialog, count, total = @category_scan_events.pop
          next unless @dialog.equal?(dialog) && @dialog[:busy]

          @category_scan_label.text = "جارٍ جمع الكتب… \u2066#{format_number(count)} / #{format_number(total)}\u2069"
        end
        (@category_progress_views || {}).each_value { |view| update_category_progress(view) }
        current = @download_queue.current
        if current && (label = @category_book_labels&.[](current.dig(:book, "id")))
          label.text = download_message(current)
        end
      end

      def category_download_card(group)
        id = group.fetch(:category_id)
        category = { "id" => id, "name" => group.fetch(:name) }
        expanded = (@expanded_download_categories ||= {})[id]
        card(padding: 16) do
          row do
            para group.fetch(:name), width: -144, size: 20, wrap: "trim", tooltip: group.fetch(:name)
            action(expanded ? "إخفاء الكتب" : "عرض الكتب", icon: "chevron-down",
              width: 144, variant: :ghost, key: [:category_details, id]) do
              @expanded_download_categories[id] = !expanded
              draw_window
            end
          end
          counts = "\u2066#{format_number(group[:done])} / #{format_number(group[:total])}\u2069 كتاب مكتمل"
          counts += " · #{format_number(group[:failed])} يحتاج إلى المحاولة" if group[:failed].positive?
          counts += " · #{format_number(group[:cancelled])} ملغى" if group[:cancelled].positive?
          para counts, size: 14, stroke: muted, margin_top: 4
          label = para "", size: 14, stroke: muted, margin_top: 8, wrap: "trim"
          bar = progress(width: 1.0, height: 14, margin_top: 8)
          view = @category_progress_views[id] = { group:, label:, bar: }
          update_category_progress(view)
          row(height: 48, margin_top: 12) { category_download_actions(category, group) }
          if expanded
            separator(margin_top: 16, margin_bottom: 8)
            page = (@category_download_pages ||= {}).fetch(id, 1)
            filter = @download_filter || :all
            count = { all: group[:total], done: group[:done], active: group[:total] - group[:done] }.fetch(filter)
            pages = [count.fdiv(Store::PAGE_SIZE).ceil, 1].max
            page = @category_download_pages[id] = [page, pages].min
            @download_queue.entries(category_id: id, page:, filter:).each do |book_id, download|
              row(height: 78) do
                stack(width: -312) do
                  para Text.plain(download.fetch(:book).fetch("title")), size: 16, wrap: "trim",
                    tooltip: Text.plain(download.fetch(:book).fetch("title"))
                  @category_book_labels[book_id] = para download[:status] == :done ? "متاح للقراءة والبحث دون اتصال" : download_message(download),
                    size: 13, stroke: muted, margin_top: 4, wrap: "trim"
                end
                row(width: 312) { download_actions(book_id, download) }
              end
            end
            page_controls(page:, previous: page > 1, following: page < pages) do |number|
              @category_download_pages[id] = number
              draw_window
            end
          end
        end
      end

      def update_category_progress(view)
        group = view.fetch(:group)
        current = @download_queue.current
        active = current && current[:category_id] == group[:category_id]
        fraction = group[:done].fdiv(group[:total])
        fraction += current.fetch(:fraction).fdiv(group[:total]) if active && current[:status] == :downloading
        smooth_progress(view.fetch(:bar), fraction.clamp(0, 1))
        message = if active
          "#{Text.plain(current.fetch(:book).fetch('title'))} · #{download_message(current)}"
        elsif group[:queued].positive?
          "#{format_number(group[:queued])} كتاب في قائمة الانتظار"
        elsif group[:cancelling].positive?
          "جارٍ إلغاء التنزيلات غير المكتملة…"
        elsif group[:paused].positive? || group[:pausing].positive?
          "متوقف مؤقتًا · يمكنك المتابعة لاحقًا"
        elsif group[:failed].positive?
          "يمكنك إعادة محاولة الكتب التي تعذّر تنزيلها."
        elsif group[:done] == group[:total]
          "اكتمل · متاح للقراءة والبحث دون اتصال"
        else
          "أُلغي التنزيل · الكتب المكتملة محفوظة في مكتبتك"
        end
        view.fetch(:label).text = message
        view.fetch(:label).tooltip = message
      end

      def category_download_actions(category, group)
        id = category.fetch("id")
        if group[:queued].positive? || group[:downloading].positive?
          action("إيقاف مؤقت", icon: "pause", width: 144, margin_right: 12, key: [:pause_category, id]) { change_category_download(category, :pause) }
        elsif group[:pausing].positive? || group[:cancelling].positive?
          action(group[:pausing].positive? ? "جارٍ الإيقاف…" : "جارٍ الإلغاء…", width: 144, margin_right: 12, state: "disabled")
        elsif group[:paused].positive? || group[:cancelled].positive?
          action("متابعة التنزيل", icon: "play", width: 158, margin_right: 12, key: [:resume_category, id]) { change_category_download(category, :resume) }
        end
        if group[:failed].positive?
          action("إعادة محاولة المتعثرة", width: 180, margin_right: 12, key: [:retry_category, id]) { change_category_download(category, :retry) }
        end
        if group[:done] == group[:total]
          action("فتح كتب التصنيف", icon: "book-open", width: 180) { navigate(:saved, filters: { category: id }, label: category.fetch("name")) }
        elsif group[:queued] + group[:downloading] + group[:paused] + group[:failed] + group[:pausing] > 0
          action("إلغاء التنزيل", width: 124, variant: :ghost, key: [:cancel_category, id]) { change_category_download(category, :cancel) }
        end
      end

      def change_category_download(category, action)
        id = category.fetch("id")
        case action
        when :pause then @download_queue.pause_category(id)
        when :cancel then @download_queue.cancel_category(id)
        when :resume then @download_queue.resume_category(category)
        when :retry then @download_queue.resume_category(category, failed_only: true)
        end
        @notifications.dismiss([:category_download, id])
        refresh_download_state
      end

      def notify_category_download(id)
        group = @store.category_downloads.find { |item| item[:category_id] == id }
        return unless group
        return if %i[queued downloading pausing paused cancelling].any? { |state| group[state].positive? }
        return unless group[:failed].positive? || group[:done] == group[:total]

        failed = group[:failed].positive?
        @notifications.push([:category_download, id], persistent: failed) do
          { error: failed, message: failed ? "#{format_number(group[:failed])} كتب تحتاج إلى المحاولة" : "اكتمل تنزيل التصنيف",
            detail: group.fetch(:name), action_label: "عرض التنزيلات", action: -> { navigate(:downloads) } }
        end
      end
    end
  end
end
