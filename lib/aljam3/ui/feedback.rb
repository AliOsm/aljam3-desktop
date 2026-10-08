# frozen_string_literal: true

module Aljam3
  module UI
    module Feedback
      def notify_download(download)
        @analytics&.count(download[:status] == :failed ? :downloads_failed : :downloads_completed)
        return notify_category_download(download[:category_id]) if download[:category_id]

        book = download.fetch(:book)
        if download.fetch(:status) == :failed
          failures = [*@notifications.find(:download_failed)&.fetch(:downloads, []), download]
          return notify_download_failure(failures.uniq { |item| item.fetch(:book).fetch("id") })
        end
        resolve_download_failure(book.fetch("id"))
        @notifications.push(:download_done) do |count|
          {
            message: count == 1 ? "جاهز للقراءة والبحث دون اتصال" : "#{format_number(count)} كتب جاهزة دون اتصال",
            detail: count == 1 ? Text.plain(book.fetch("title")) : "اكتمل حفظ الكتب ونصوصها للبحث.",
            action_label: count > 1 ? "عرض التنزيلات" : "فتح الكتاب",
            action: -> { count > 1 ? navigate(:downloads) : open_book(book) }
          }
        end
      end

      def notify_download_failure(downloads)
        return @notifications.dismiss(:download_failed) if downloads.empty?

        count, last = downloads.length, downloads.last
        cancelling = last[:failure] == "cancel"
        @notifications.push(:download_failed, persistent: true) do
          { error: true, count:, downloads:, message: count > 1 ? "#{format_number(count)} تنزيلات تحتاج إلى المحاولة" : (cancelling ? "تعذّر إلغاء التنزيل" : "تعذّر تنزيل الكتاب"),
            detail: last.fetch(:message), action_label: count == 1 ? "إعادة المحاولة" : "عرض التنزيلات",
            action: -> {
              if count > 1
                navigate(:downloads)
              elsif cancelling
                cancel_download(last.fetch(:book).fetch("id"))
              else
                queue_download(last.fetch(:book))
              end
            } }
        end
      end

      def resolve_download_failure(id)
        notice = @notifications.find(:download_failed)
        notify_download_failure(notice.fetch(:downloads).reject { |item| item.fetch(:book).fetch("id") == id }) if notice
      end

      def draw_feedback
        @notification_view = nil
        @notification_action_views = {}
        @notification_hover = @notification_focus = @notification_entering = false
        @notification_layer = stack(left: 0, top: 0, width: 0, height: 0, overlay: true)
        update_notification
      end

      def tick_feedback
        @notifications.tick(paused: dialog_active? || @notification_hover || @notification_focus || @notification_entering)
        update_notification
        update_activity
        if @dialog&.dig(:type) == :export && (download = @download_queue.current) && download.dig(:book, "id") == @reader.dig(:book, "id")
          smooth_progress(@export_download_progress, download.fetch(:fraction), group: :dialog) if @export_download_progress
        end
      end

      def update_notification
        if dialog_active?
          clear_notification if @notification_view || @notification_entering || @notification_layer.style[:width].positive?
          @notification_view = nil
          return
        end
        notice = @notifications.current
        return if @notification_view.equal?(notice)

        if notice && @notification_view&.fetch(:key) == notice.fetch(:key) &&
            !!@notification_view[:action] == !!notice[:action] && @notification_view[:error] == notice[:error]
          @notice_message.text = notice.fetch(:message)
          @notice_detail.text = notice.fetch(:detail)
          @notice_detail.tooltip = notice.fetch(:detail)
          @notice_action.text = notice.fetch(:action_label) if @notice_action
        elsif !notice && @notification_view && !dialog_active?
          @notification_layer.inert = true
          @notification_view = nil
          @motion.to(@notification_layer, opacity: 0.0, displace_top: 6,
            duration: 0.10, group: :feedback, complete: -> { clear_notification })
          return
        else
          clear_notification
          draw_notification(notice) if notice
        end
        @notification_view = notice
      end

      def clear_notification
        @motion.cancel(:feedback)
        @notification_hover = @notification_focus = @notification_entering = false
        @notification_layer.clear
        @action_views.delete([:notification, :close])
        @action_views.delete([:notification, :action])
        @notification_action_views = {}
        @notification_layer.style(width: 0, height: 0, opacity: 1.0, displace_top: 0, inert: false)
      end

      def draw_notification(notice)
        panel_width = [420, width - PAGE_MARGIN * 2].min
        panel_height = notice[:action] ? 112 : 80
        bottom_gap = @screen == :reader ? 92 : 12
        @notification_rest_top = height - STATUS_HEIGHT - bottom_gap - panel_height
        @notification_layer.style(left: width - PAGE_MARGIN - panel_width,
          top: @notification_rest_top, displace_top: 6, width: panel_width, height: panel_height, opacity: 0.0)
        @drawing_notification = true
        @notification_layer.append do
          background @theme == :dark ? paper : surface, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          row(left: 12, top: 8, width: panel_width - 24, height: 32) do
            image asset_path("icons", notice[:error] ? "download" : "check"), width: 32, height: 20, margin_right: 8
            @notice_message = para notice.fetch(:message), width: -60, size: 15,
              stroke: notice[:error] ? primary : ink, wrap: "trim", live: "polite"
            close = icon_button("x", "إغلاق الإشعار", key: [:notification, :close], width: 28, height: 28) { dismiss_notification }
            close.focus_changed = proc { |_control, focused| @notification_focus = focused }
          end
          @notice_detail = para notice.fetch(:detail), left: 16, top: 43, width: panel_width - 32,
            size: 14, stroke: muted, wrap: "trim", tooltip: notice.fetch(:detail)
          @notice_action = nil
          if notice[:action]
            @notice_action = action(notice.fetch(:action_label), key: [:notification, :action], right: 12, top: 76,
              width: 150, height: 28, size: 14, variant: :ghost) do
              callback = @notifications.current.fetch(:action)
              dismiss_notification
              callback.call
            end
            @notice_action.focus_changed = proc { |_control, focused| @notification_focus = focused }
          end
        end
        @notification_action_views = @action_views.select { |key, _| key.is_a?(Array) && key.first == :notification }
        @notification_entering = true
        @motion.to(@notification_layer, opacity: 1.0, displace_top: 0, duration: 0.18,
          group: :feedback, complete: -> { @notification_entering = false })
        @notification_layer.hover { @notification_hover = true }
        @notification_layer.leave { @notification_hover = false }
      ensure
        @drawing_notification = false
      end

      def position_notification
        return unless @notification_view

        gap = @screen == :reader ? 92 : 12
        @notification_rest_top = height - STATUS_HEIGHT - gap - @notification_layer.style[:height]
        @notification_layer.top = @notification_rest_top
      end

      def dismiss_notification
        focused = @notification_focus
        @notifications.dismiss
        update_notification
        @last_content_focus&.focus if focused
      end

      def copy_with_feedback(text, control:, label: "")
        self.clipboard = text
        icon_theme = control.style[:variant] == "solid" ? :dark : @theme
        control.style(text: label.empty? ? "" : "تم النسخ", icon: asset_path("icons", "check", theme: icon_theme), tooltip: "تم النسخ")
        (@copy_receipts ||= {})[control.linkable_id] = receipt = Object.new
        schedule_once(2) do
          next unless @copy_receipts[control.linkable_id].equal?(receipt)

          @copy_receipts.delete(control.linkable_id)
          if @action_views.value?(control)
            control.style(text: label, icon: asset_path("icons", "copy", theme: icon_theme), tooltip: label.empty? ? "نسخ نص الصفحة" : label)
          end
        end
      rescue StandardError => error
        report_error(error, operation: :cache)
        warn error.full_message
        control.tooltip = "تعذّر النسخ. حاول مرة أخرى."
      end

      def connection_message
        { offline: "دون اتصال · كتبك المحمّلة متاحة", unavailable: "الجامع غير متاح · كتبك المحمّلة متاحة",
          online: "متصل بالجامع" }.fetch(@connection, "جارٍ التحقق من الاتصال…")
      end

      def update_connection
        @connection_text.text = connection_message
        @reconnect_button.style(hidden: !%i[offline unavailable].include?(@connection))
      end

      def draw_activity
        @download_states = @store.download_state_counts
        @activity_button = action("", icon: "download", width: 258, height: 28, size: 13, variant: :ghost) { navigate(:downloads) }
        @file_activity_label = para "", width: 258, size: 13, stroke: muted, wrap: "trim", hidden: true
        @activity_progress = progress(width: 64, height: 6, margin_right: 8)
        @activity_text = nil
        update_activity
      end

      def update_activity
        return unless @activity_button

        current = @download_queue.current
        states = @download_states || {}
        saving = (@file_operations || {}).values.count { |job| job[:status] == :saving }
        message = if current && %i[pausing cancelling].include?(current[:status])
          current[:status] == :pausing ? "جارٍ إيقاف التنزيل…" : "جارٍ إلغاء التنزيل…"
        elsif current
          phase = current.fetch(:message).start_with?("حفظ النص") ? "تجهيز البحث" : "جارٍ التنزيل"
          "#{phase} · #{format_number((current.fetch(:fraction) * 100).floor)}%"
        elsif states.fetch(:queued, 0).positive?
          "#{format_number(states[:queued])} في قائمة التنزيل"
        elsif states.fetch(:failed, 0).positive?
          states[:failed] == 1 ? "تنزيل يحتاج إلى المحاولة" : "#{format_number(states[:failed])} تنزيلات تحتاج إلى المحاولة"
        elsif states.fetch(:paused, 0).positive?
          states[:paused] == 1 ? "تنزيل متوقف مؤقتًا" : "#{format_number(states[:paused])} تنزيلات متوقفة مؤقتًا"
        end
        file_message = saving == 1 ? "جارٍ حفظ ملف…" : "جارٍ حفظ #{format_number(saving)} ملفات…" if saving.positive?
        message = [message, file_message].compact.join(" · ")
        @activity_progress.style(hidden: !current)
        smooth_progress(@activity_progress, current&.fetch(:fraction) || 0, group: :chrome)
        return if @activity_text == message

        @activity_text = message
        files_only = !current && states.values.sum.zero? && saving.positive?
        @activity_button.style(text: message, hidden: message.empty? || files_only, tooltip: message)
        @file_activity_label.style(hidden: !files_only)
        @file_activity_label.text = message if files_only
      end
    end
  end
end
