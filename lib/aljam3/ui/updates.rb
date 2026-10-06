# frozen_string_literal: true

require_relative "../updates"

module Aljam3
  module UI
    module UpdateScreen
      def setup_updates(directory)
        @updater = Updates.new(directory:)
        @update_worker = Worker.new
        @workers << @update_worker
        @update_events = Queue.new
        @update_state = :idle
        @update_fraction = 0
        result = File.join(@updater.directory, "result.txt")
        if File.file?(result)
          outcome = File.read(result).strip
          failed = outcome != "installed"
          @notifications.push(:update_result, persistent: failed) do
            if outcome == "move_to_applications"
              { error: true, message: "انقل الجامع إلى مجلد التطبيقات",
                detail: "أغلق الجامع، واسحبه إلى Applications باستخدام Finder، ثم افتحه من هناك وأعد التحديث." }
            else
              { error: failed, message: failed ? "تعذّر تثبيت التحديث" : "تم تحديث الجامع",
                detail: failed ? "يمكنك المحاولة مجددًا من تحديثات التطبيق. كتبك وموضع القراءة محفوظة." : "الإصدار #{@updater.version} جاهز للقراءة." }
            end
          end
          FileUtils.rm_f(result)
        end
        return unless @updater.supported?
        @update_state = :restoring
        @update_worker.submit(-> { @updater.cached }) do |package, _error|
          @update_package = package
          @update_state = package ? :ready : :idle
          notify_update_ready if package
          refresh_update_dialog
        end
      end

      def tick_updates
        until @update_events.empty?
          @update_fraction = @update_events.pop
        end
        @update_progress.fraction = @update_fraction if @dialog&.dig(:type) == :updates && @update_progress
        return unless @updater.supported? && %i[idle current error].include?(@update_state)
        return if Time.now.to_i - @store.preference("update_checked_at", 0) < Updates::INTERVAL

        check_updates
      end

      def check_updates
        return unless @updater.supported? && %i[idle current error].include?(@update_state)
        @store.save_preference("update_checked_at", Time.now.to_i)
        @update_state = :checking
        refresh_update_dialog
        @update_worker.submit(-> { @updater.check }) do |package, error|
          if error
            update_failed(error)
          elsif package
            @update_package = package
            @update_state, @update_fraction = :downloading, 0
            refresh_update_dialog
            @update_worker.submit(-> { @updater.download(package) { |fraction| @update_events << fraction } }) do |_path, failure|
              if failure
                update_failed(failure)
              else
                @update_state = :ready
                notify_update_ready
                refresh_update_dialog
              end
            end
          else
            @update_state = :current
            refresh_update_dialog
          end
        end
      end

      def notify_update_ready
        @notifications.push(:update_ready, persistent: true) do
          { message: "تحديث الجامع جاهز", detail: "الإصدار #{@update_package.fetch('version')} · كتبك وموضع القراءة محفوظة",
            action_label: "عرض التحديث", action: -> { open_dialog(:updates) } }
        end
      end

      def update_failed(error)
        warn "Update: #{error.class}: #{error.message}"
        @update_state = :error
        refresh_update_dialog
      end

      def refresh_update_dialog
        refresh_dialog if @dialog&.dig(:type) == :updates
      end

      def restart_for_update
        return unless @update_state == :ready
        if @file_operations.values.any? { |job| job[:status] == :saving }
          @update_wait_for_export = true
          return refresh_update_dialog
        end
        @update_wait_for_export = false
        @update_state = :installing
        refresh_update_dialog
        @update_worker.submit(-> { @updater.install(@update_package) }) do |_result, error|
          error ? update_failed(error) : close
        end
      end

      def draw_updates
        @update_progress = nil
        para "الإصدار الحالي: #{@updater.version}", size: 15, stroke: muted
        text = if !@updater.supported?
          "تتوفر التحديثات في النسخة المثبّتة على macOS وWindows."
        else
          { idle: "يتحقق الجامع من التحديثات تلقائيًا كل يوم.", restoring: "جارٍ التحقق من التحديث المحفوظ…", checking: "جارٍ التحقق من التحديثات…",
            current: "لديك أحدث إصدار من الجامع.", downloading: "جارٍ تنزيل الإصدار #{@update_package&.fetch('version')} في الخلفية…",
            ready: "الإصدار #{@update_package&.fetch('version')} جاهز للتثبيت.", installing: "جارٍ تجهيز التحديث وإعادة التشغيل…",
            error: "تعذّر إكمال التحديث. تحقق من الاتصال والمساحة المتاحة ثم حاول مجددًا." }.fetch(@update_state)
        end
        para text, top: 34, size: 16, stroke: ink, live: "polite"
        if @update_state == :downloading
          @update_progress = progress(top: 96, width: 1.0, height: 6)
          @update_progress.fraction = @update_fraction
        elsif @update_state == :ready
          para(@update_wait_for_export ? "انتظر اكتمال حفظ الملفات ثم أعد المحاولة." : "سنحفظ موضع القراءة وتُستأنف تنزيلات الكتب بعد إعادة التشغيل.", top: 86, size: 14, stroke: muted)
          action("إعادة التشغيل والتحديث", top: 144, right: 0, width: 204, variant: :solid) { restart_for_update }
        elsif @updater.supported? && %i[idle current error].include?(@update_state)
          action("التحقق من التحديثات", top: 144, right: 0, width: 204, variant: :solid) { check_updates }
        end
      end
    end
  end
end
