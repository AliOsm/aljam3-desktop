# frozen_string_literal: true

require_relative "../storage"

module Aljam3
  module UI
    module SettingsScreen
      def open_library_services(directory)
        @api ||= API.new(base_url: ENV.fetch("ALJAM3_API_URL", "https://aljam3.com"))
        @store = Store.new(File.join(directory, "library.sqlite3"), create: !@storage.selected?)
        @library = Library.new(api: @api, store: @store,
          on_error: ->(error) { @analytics&.capture_error(error, operation: :catalog_fallback, context: { fallback: true }) })
        @downloader = Downloader.new(api: @api, store: @store, directory: File.join(directory, "books"))
        @reading = Reading.new(api: @api, store: @store, downloader: @downloader)
        @pdf = PDF.new(cache: File.join(directory, "renders"))
        @network_worker, @render_worker, @page_worker, @export_worker, @category_worker = %i[network pdf text export category].map { |operation| diagnostic_worker(operation) }
        @workers.concat([@network_worker, @render_worker, @page_worker, @export_worker, @category_worker])
        @download_queue = Downloads.new(store: @store, downloader: @downloader,
          on_error: ->(error, context) { report_error(error, operation: context.fetch(:operation, :download), context:) },
          on_activity: ->(status) { @analytics&.breadcrumb(:download, status:) }) { |download| notify_download(download) }
        @downloaded_ids = @store.downloaded_ids
        @categories, @libraries = @store.preference("categories", []), @store.preference("libraries", [])
      end

      def close_library_services(strict: false)
        errors = []
        @reader_pump&.remove
        @reader_pump = nil
        @workers.reject { |worker| worker.equal?(@update_worker) }.each(&:close)
        @workers = [@update_worker].compact
        %i[download_queue pdf reading store].each do |name|
          instance_variable_get("@#{name}")&.close
        rescue StandardError => error
          report_error(error, operation: :shutdown)
          errors << error
          warn "Closing library #{name}: #{error.message}"
        ensure
          instance_variable_set("@#{name}", nil)
        end
        raise errors.first if strict && errors.any?
      end

      def finish_library_app
        @closing = true
        @ticker&.remove
        @preference_ticker&.remove
        @motion.cancel
        @library_transfer&.cancel
        @storage_worker.close
        save_reader_position if @store && @screen == :reader
      rescue StandardError => error
        report_error(error, operation: :shutdown)
        raise
      ensure
        begin
          close_library_services
          @update_worker&.close
          @library_transfer&.release
          @previous_library_instance&.close
          @library_instance&.close
          @instance.close
        rescue StandardError => error
          report_error(error, operation: :shutdown)
          raise
        ensure
          finish_analytics
        end
      end

      def open_settings
        @settings_message = nil
        open_dialog(:settings)
        measure_library
      end

      def measure_library
        storage = @storage
        @storage_worker.submit(-> { storage.bytes }) do |bytes, error|
          next if @library_moving || @library_unavailable

          @library_bytes = error ? nil : bytes
          @library_size_error = !!error
          @library_size_label.text = library_size_label if @dialog&.dig(:type) == :settings
        end
      end

      def library_size_label
        return "تعذّر حساب المساحة المستخدمة." if @library_size_error

        @library_bytes ? "المساحة المستخدمة: #{format_bytes(@library_bytes)}" : "جارٍ حساب المساحة المستخدمة…"
      end

      def settings_dialog_height = 316 + update_dialog_height + (@settings_message ? 48 : 0)

      def library_path(path, **styles)
        stack(height: 36, **styles) do
          background surface, curve: CARD_RADIUS
          border line_color, curve: CARD_RADIUS
          para "\u2066#{path}\u2069", left: 10, top: 8, width: -20, size: 14, align: "left", wrap: "trim", tooltip: path
        end
      end

      def draw_settings
        para "المكتبة", size: 19, font: HEADING_FONT
        library_path(@storage.directory, top: 36, width: 1.0)
        @library_size_label = para library_size_label, top: 84, size: 14, stroke: muted, live: "polite"
        row(top: 116) do
          action("نقل المكتبة", icon: "folder", width: 164, margin_right: 12, key: :move_library) { choose_library_destination }
          para "نقل الكتب وبيانات القراءة إلى مجلد فارغ.", width: -164, size: 14, stroke: muted
        end
        extra = @settings_message ? 48 : 0
        para @settings_message, top: 164, size: 14, stroke: primary, live: "polite" if @settings_message
        separator(top: 168 + extra, width: 1.0)
        para "إحصاءات الاستخدام", top: 184 + extra, size: 19, font: HEADING_FONT
        para "تُرسل إلى PostHog إحصاءات الاستخدام وتقارير تقنية عن الأخطاء.", top: 216 + extra, size: 14, stroke: muted
        para "بمعرّف تثبيت عشوائي، دون عناوين الكتب أو نصوص البحث.", top: 240 + extra, size: 14, stroke: muted
        separator(top: 264 + extra, width: 1.0)
        para "تحديثات التطبيق", top: 280 + extra, size: 19, font: HEADING_FONT
        @settings_updates = stack(top: 316 + extra, width: 1.0, height: update_dialog_height - 80) { draw_updates }
      end

      def library_move_blocked?
        @update_state == :installing || @clearing_cache || @export_worker.busy? ||
          @file_operations.values.any? { |job| job[:status] == :saving }
      end

      def choose_library_destination
        if library_move_blocked?
          @settings_message = "انتظر اكتمال حفظ الملفات والعمليات الجارية ثم أعد المحاولة."
          return refresh_dialog
        end
        path = ask_open_folder
        return if path.to_s.empty?

        transfer = @storage.prepare(path, app_lock: @instance)
        transfer.release
        open_dialog(:move_library, nested: true, destination: transfer.destination)
      rescue StandardError => error
        @settings_message = storage_error_message(error)
        refresh_dialog
      end

      def draw_library_move
        if @library_moving
          para "جارٍ نقل المكتبة والتحقق من الملفات…", size: 18, live: "polite"
          library_path(@library_transfer.destination, top: 36, width: 1.0)
          @library_move_progress = progress(top: 92, width: 1.0, height: 6)
          @library_move_progress.fraction = @library_move_fraction || 0
          @library_move_label = para library_move_label, top: 112, size: 14, stroke: muted, live: "polite"
          para "تُستأنف تنزيلات الكتب تلقائيًا بعد اكتمال النقل.", top: 148, size: 14, stroke: muted
          action("إلغاء النقل", right: 0, top: 188, width: 144, key: :cancel_library_move,
            state: @library_move_cancelling || @library_move_finishing ? "disabled" : nil) do
            @library_move_cancelling = true
            @library_transfer.cancel
            refresh_dialog
          end
        else
          para "المجلد الجديد", size: 17
          library_path(@dialog.fetch(:destination), top: 36, width: 1.0)
          para "سننقل مكتبتك كاملة، ثم نحذف النسخة القديمة بعد التحقق من الملفات.", top: 88, size: 15
          para "تتوقف القراءة والتنزيلات مؤقتًا أثناء النقل. يمكنك إلغاء النقل.", top: 120, size: 14, stroke: muted
          para @dialog[:error], top: 152, size: 14, stroke: primary, live: "polite" if @dialog[:error]
          row(top: @dialog[:error] ? 188 : 152) do
            action("نقل المكتبة", width: 156, margin_right: 12, variant: :solid, key: :confirm_library_move) { begin_library_move }
            action("رجوع", width: 88) { close_dialog }
          end
        end
      end

      def library_move_label
        return "اكتمل النقل. جارٍ تجهيز المكتبة…" if @library_move_finishing

        @library_move_cancelling ? "جارٍ إلغاء النقل…" : "#{format_number(((@library_move_fraction || 0) * 100).floor)}% · الكتب والفهرس وبيانات القراءة"
      end

      def begin_library_move
        return if @library_moving
        if library_move_blocked?
          @dialog[:error] = "انتظر اكتمال حفظ الملفات ثم أعد المحاولة."
          return refresh_dialog
        end
        @library_transfer = @storage.prepare(@dialog.fetch(:destination), app_lock: @instance)
        @library_return = library_location
        @library_moving = true
        @library_move_finishing = false
        @library_move_fraction, @library_move_cancelling = 0, false
        @library_move_events = Queue.new
        @request_number += 1
        @render_number += 1
        @page_request += 1
        close_library_services(strict: true)
        @file_operations.clear
        @notifications.dismiss(:export_failed)
        refresh_dialog
        transfer = @library_transfer
        @storage_worker.submit(-> { transfer.run { |fraction| @library_move_events << fraction } }) do |_path, error|
          complete_library_move(error)
        end
      rescue StandardError => error
        @library_transfer&.release
        return complete_library_move(error) if @library_moving

        @dialog[:error] = storage_error_message(error)
        refresh_dialog
      end

      def tick_library_move
        @library_move_fraction = @library_move_events.pop until @library_move_events.empty?
        @library_move_progress.fraction = @library_move_fraction if @library_move_progress
        @library_move_label.text = library_move_label if @library_move_label
        # Rebuild only the dialog on resize: all library connections are closed.
        if @viewport != [width, height]
          @viewport = [width, height]
          clear_dialog_view
          @dialog_layer.style(width:, height:)
          render_dialog
        end
      end

      def complete_library_move(error)
        transfer = @library_transfer
        @library_move_finishing = true
        if transfer.committed?
          @previous_library_instance = @library_instance
          @library_instance = File.identical?(transfer.destination, @storage.app_directory) ? nil : transfer.lock
        end
        open_library_services(@storage.resolve!)
        if transfer.committed?
          refresh_dialog
          @storage_worker.submit(-> { transfer.cleanup_source }) do |cleaned, cleanup_error|
            finish_library_move(error, cleaned: cleaned && !cleanup_error)
          end
        else
          finish_library_move(error, cleaned: true)
        end
      rescue StandardError => failure
        @library_moving = false
        @previous_library_instance&.close
        @previous_library_instance = nil
        close_library_services
        show_library_recovery(failure)
      end

      def finish_library_move(error, cleaned:)
        @analytics&.count(:library_moves) if @library_transfer&.committed?
        @library_moving = false
        @previous_library_instance&.close
        @previous_library_instance = nil
        @library_transfer = nil
        @dialog = nil
        @dialog_stack = []
        @pdf_volume = @pdf_pending = nil
        release_pdf_images
        restore_location(@library_return)
        @library_return = nil
        @settings_message = if error
          storage_error_message(error)
        elsif cleaned
          "تم نقل المكتبة. تُحفظ الكتب الجديدة في المجلد المحدد."
        else
          "تم نقل المكتبة. تعذّر حذف بعض الملفات القديمة؛ يمكنك حذفها يدويًا."
        end
        @library_bytes = nil
        open_dialog(:settings)
        measure_library
      rescue StandardError => failure
        close_library_services
        show_library_recovery(failure)
      end

      def storage_error_message(error)
        report_error(error, operation: :storage)
        case error
        when Storage::Error then error.message
        when Errno::EACCES, Errno::EROFS then "لا يمكن الكتابة في هذا المجلد. اختر مجلدًا تملك صلاحية الكتابة فيه."
        when Errno::ENOENT, Errno::ENODEV then "المجلد غير متاح. تحقق من توصيل القرص ثم أعد المحاولة."
        else error_message(error)
        end
      end

      def check_library_available
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return true if @library_checked_at && now - @library_checked_at < 1

        @library_checked_at = now
        return true if @storage.available?

        @library_return = library_location rescue nil
        close_library_services
        @library_instance&.close
        @library_instance = nil
        show_library_recovery(Storage::Unavailable.new("لم يتم العثور على مجلد المكتبة المحدد."))
        false
      end

      def library_location
        location = current_location
        # An unfinished online open belongs to the worker we are stopping.
        # Restore the catalog so it cannot leave an orphaned loading screen.
        if location[:screen] == :opening
          screen = @catalog_return&.dig(:screen)
          location[:screen] = %i[home browse categories authors saved downloads].include?(screen) ? screen : :home
          location[:scroll] = { results: @catalog_return&.dig(:scroll) || 0 }
        end
        location
      end

      def show_library_recovery(error)
        @theme ||= system_theme
        apply_theme
        @library_unavailable = true
        @storage_error = storage_error_message(error)
        @screen = :library_unavailable
        @dialog = @closing_dialog = nil
        @dialog_stack = []
        @motion.cancel
        draw_library_recovery
      end

      def tick_library_recovery
        draw_library_recovery if @viewport != [width, height]
      end

      def draw_library_recovery
        @viewport = [width, height]
        @action_views = {}
        clear do
          background paper
          image asset_path("brand", "aljam3"), right: 24, top: 16, width: 60, height: 40
          stack(left: (width - 600) / 2, top: (height - 300) / 2, width: 600, height: 300, padding: 20) do
            background card_color, curve: CARD_RADIUS
            border line_color, curve: CARD_RADIUS
            para "المكتبة غير متاحة", size: 24, font: HEADING_FONT
            para "أعد توصيل القرص الذي يحتوي على مكتبتك، ثم اضغط إعادة المحاولة.", top: 44, size: 16
            library_path(@storage&.directory || Aljam3.data_directory, top: 84, width: 1.0)
            para @storage_error, top: 136, size: 14, stroke: primary, live: "polite"
            para "إذا تغيّر موقع المجلد، حدّد موقع المكتبة لاستئناف القراءة.", top: 180, size: 14, stroke: muted
            row(top: 224) do
              action("إعادة المحاولة", width: 156, margin_right: 12, variant: :solid, key: :retry_library) { reconnect_library }
              action("تحديد موقع المكتبة", width: 176, key: :locate_library) { locate_library }
            end
          end
        end
      end

      def reconnect_library
        start_library_app
        if !@library_unavailable && @library_return
          restore_location(@library_return)
          @library_return = nil
        end
      end

      def locate_library
        path = ask_open_folder
        return if path.to_s.empty?

        @library_instance&.close
        @library_instance = @storage.locate(path)
        reconnect_library
      rescue StandardError => error
        show_library_recovery(error)
      end
    end
  end
end
