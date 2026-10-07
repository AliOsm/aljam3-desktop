# frozen_string_literal: true

require "timeout"
require_relative "alignment_verification"
require_relative "range_pdf"

class SettingsVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks = []
  end

  def call
    MotionPreference.set(@app, reduced: true)
    get(:ticker).remove
    # Packaged apps can already be checking the public feed. These UI scenarios
    # control update states explicitly; discard any late real-network callback.
    get(:workers).delete(get(:update_worker))
    get(:update_worker).close
    set(update_worker: Aljam3::Worker.new, update_state: :current)
    get(:workers) << get(:update_worker)
    get(:store).save_preference("update_checked_at", Time.now.to_i)
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    wait { ready }
    seed
    updater = get(:updater)
    updater.define_singleton_method(:supported?) { true }
    set(update_state: :current)
    %i[light dark].each do |theme|
      set(theme:)
      @app.apply_theme
      [[1160, 820], [800, 600]].each do |width, height|
        @automation.resize(width, height)
        @app.draw_window
        activate(action(:settings))
        wait { get(:library_bytes) }
        check("Gear opens Settings with keyboard", get(:dialog)[:type] == :settings)
        check_panel("#{theme}-#{width}")
        shot("#{theme}-#{width}-settings")
        @automation.key("escape")
      end
    end
    set(update_state: :restoring)
    @app.open_settings
    set(update_state: :ready, update_package: { "version" => "0.0.2" }, settings_message: "اختر مجلدًا فارغًا لحفظ المكتبة؛ لن ندمجها مع ملفات أخرى.")
    @app.refresh_update_dialog
    check_panel("ready update with feedback at minimum size")
    @app.close_dialog
    @automation.resize(1160, 820)
    set(theme: :light)
    @app.apply_theme
    @app.draw_window
    badge_and_updates
    cancelled_folder_picker
    nonempty_destination
    export_guard
    relocation
    cancelled_relocation
    disconnected_drive
    move_back_to_default
    { passed: true, checks: @checks }
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |key, value| @app.instance_variable_set("@#{key}", value) }
  def action(key) = get(:action_views).fetch(key)
  def click(control) = @automation.click({ id: control.linkable_id })
  def activate(control)
    control.focus
    @automation.key("enter")
  end
  def check(label, result)
    raise label unless result

    @checks << label
  end
  def shot(name) = @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1)
  def wait
    Timeout.timeout(15) do
      loop do
        @app.tick
        @automation.wait_frames
        break if yield

        sleep 0.005
      end
    end
  end

  def picker(path) = @app.define_singleton_method(:ask_open_folder) { path }

  def seed
    store = get(:store)
    @book = Marshal.load(Marshal.dump(AlignmentVerification::BOOKS[1]))
    @book["pages_count"] = @book["files"][0]["pages_count"] = 6
    store.prepare_download(@book)
    store.add_pages(@book.fetch("id"), (1..6).map do |number|
      { "id" => @book.fetch("id") * 10 + number, "number" => number, "content" => "العلم نور. نص الصفحة #{number}." }
    end)
    pdf = RangePDF.document(pages: 6)
    path = get(:downloader).pdf_path(@book.fetch("id"), @book.fetch("id"))
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, pdf)
    store.complete_download(@book.fetch("id"), bytes: pdf.bytesize)
    store.save_reading(@book.fetch("id"), file_id: @book.fetch("id"), number: 3)
    store.toggle_bookmark(@book.fetch("id"), file_id: @book.fetch("id"), number: 3, excerpt: "العلم نور")
    partial = File.join(Aljam3.data_directory, "books/.partial/777")
    FileUtils.mkdir_p(partial)
    File.binwrite(File.join(partial, "777.pdf"), "partial\n" * 1_000_000)
    store.save_preference("categories", AlignmentVerification::CATEGORIES)
    store.save_preference("libraries", AlignmentVerification::LIBRARIES)
    store.save_preference("reader", { "mode" => "split" })
    set(categories: AlignmentVerification::CATEGORIES, libraries: AlignmentVerification::LIBRARIES, downloaded_ids: store.downloaded_ids)
    @app.draw_window
  end

  def check_panel(label)
    @automation.wait_frames
    layout = @automation.layout
    panel = layout.find { |node| node[:id] == get(:dialog_panel).linkable_id }
    check("#{label}: compact dialog fits the window", panel[:x] >= 16 && panel[:y] >= 16 && panel[:x] + panel[:w] <= @app.width - 16 && panel[:y] + panel[:h] <= @app.height - 16)
    controls = get(:dialog_transition).current
    visit = lambda do |item|
      nodes = item.respond_to?(:contents) ? item.contents : []
      nodes.each do |node|
        next unless node.respond_to?(:linkable_id)

        rect = layout.find { |entry| entry[:id] == node.linkable_id }
        if rect && %w[Button Para Progress].include?(rect[:kind])
          check("#{label}: #{rect[:kind]} stays inside Settings", rect[:x] >= panel[:x] + 15 && rect[:x] + rect[:w] <= panel[:x] + panel[:w] - 15 && rect[:y] >= panel[:y] + 12 && rect[:y] + rect[:h] <= panel[:y] + panel[:h] - 15)
        end
        visit.call(node)
      end
    end
    visit.call(controls)
  end

  def badge_and_updates
    set(update_state: :ready, update_package: { "version" => "0.0.2" })
    @app.notify_update_ready
    @app.refresh_update_dialog
    check("Ready update adds a gear badge", get(:settings_badge).hidden == false)
    shot("update-badge")
    notice = get(:notifications).find(:update_ready)
    notice.fetch(:action).call
    check("Update notice opens Settings", get(:dialog)[:type] == :settings)
    check_panel("ready update")
    shot("update-ready")
    @app.close_dialog
    get(:notifications).dismiss(:update_ready)
    set(update_state: :current)
    @app.refresh_update_dialog
    check("Gear badge clears when no update is ready", get(:settings_badge).hidden)
  end

  def cancelled_folder_picker
    click(action(:settings))
    original = get(:storage).directory
    picker(nil)
    click(action(:move_library))
    check("Cancelling folder picker keeps Settings and library", get(:dialog)[:type] == :settings && get(:storage).directory == original)
  end

  def nonempty_destination
    folder = File.join(Dir.home, "Documents")
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "keep.txt"), "keep")
    picker(folder)
    activate(action(:move_library))
    check("Nonempty folder gets actionable feedback", get(:settings_message).include?("فارغًا") && File.read(File.join(folder, "keep.txt")) == "keep")
    check_panel("invalid folder")
    shot("folder-error")
  end

  def export_guard
    set(file_operations: { test: { status: :saving } })
    picker(nil)
    activate(action(:move_library))
    check("Move waits for file export", get(:settings_message).include?("انتظر") && !get(:library_moving))
    set(file_operations: {})
    @app.close_dialog
  end

  def hold_transfer
    @gate = Queue.new
    gate = @gate
    storage = get(:storage)
    storage.define_singleton_method(:prepare) do |*args, **options|
      transfer = super(*args, **options)
      transfer.define_singleton_method(:run) do |&progress|
        held = false
        super() do |fraction|
          progress.call(fraction)
          if !held && fraction > 0.2
            held = true
            gate.pop
          end
        end
      end
      transfer
    end
  end

  def relocation
    @app.open_book(@book)
    wait { get(:screen) == :reader && get(:reader)[:image] && !get(:reader)[:loading_text] }
    check("Reader starts at saved page", get(:reader)[:number] == 3)
    @app.change_zoom(0.25)
    wait { get(:reader)[:image] }
    queue_active_download
    click(action(:settings))
    @destination = File.join(Dir.home, "Libraries", "مكتبة الجامع")
    FileUtils.mkdir_p(@destination)
    @destination = File.realpath(@destination)
    picker(@destination)
    activate(action(:move_library))
    check_panel("move confirmation")
    shot("move-confirmation")
    @automation.key("escape")
    check("Back returns to Settings without moving", get(:dialog)[:type] == :settings && get(:storage).directory == Aljam3.data_directory)
    click(action(:move_library))
    hold_transfer
    activate(action(:confirm_library_move))
    wait { get(:library_move_fraction).positive? }
    @automation.key("escape")
    check("Escape keeps active move visible", get(:dialog)[:type] == :move_library && get(:library_moving))
    shot("move-progress")
    @automation.resize(800, 600)
    @app.tick
    check_panel("moving at minimum size")
    shot("move-progress-800")
    @gate << true
    wait { !get(:library_moving) }
    check("Move finishes in Settings", get(:dialog)[:type] == :settings && get(:storage).directory == @destination)
    check("Success restores reader and zoom", get(:screen) == :reader && get(:reader)[:number] == 3 && get(:reader)[:zoom] == 1.25)
    check("Search, bookmarks, and positions survive", get(:store).search("العلم").fetch("pages").length == 6 && get(:store).bookmarks(@book.fetch("id")).first["number"] == 3)
    check("Partial downloads move", File.size(File.join(@destination, "books/.partial/777/777.pdf")) == 8_000_000)
    wait { get(:store).downloaded?(123) }
    check("Active download resumes and finishes in the new folder", File.file?(File.join(@destination, "books/123/123.pdf")))
    check("Original books are removed only after success", !File.exist?(File.join(Aljam3.data_directory, "books")))
    check("Updater stays in the app directory", get(:updater).directory == File.join(Aljam3.data_directory, "updates"))
    check("A fresh session resolves chosen library", Aljam3::Storage.new.resolve! == @destination)
    check("App and library locks remain held", !Aljam3::Instance.acquire(Aljam3.data_directory) && !Aljam3::Instance.acquire(@destination))
    @automation.resize(1160, 820)
    @app.draw_window
    wait { get(:library_bytes) }
    shot("move-complete")
    @app.close_dialog
    wait { get(:reader)[:image] && !get(:pdf_pending) }
    shot("reader-after-move")
  ensure
    get(:storage).singleton_class.remove_method(:prepare) if get(:storage).singleton_methods.include?(:prepare)
  end

  def queue_active_download
    book = { "id" => 123, "title" => "كتاب قيد التنزيل", "files" => [{ "id" => 123, "name" => "الكتاب", "pages_count" => 2, "urls" => {} }], "files_count" => 1, "pages_count" => 2 }
    path = File.join(Aljam3.data_directory, "books/.partial/123")
    FileUtils.mkdir_p(path)
    File.binwrite(File.join(path, "123.pdf"), RangePDF.document(pages: 2))
    started, gate = Queue.new, Queue.new
    attempts = 0
    api = get(:api)
    api.define_singleton_method(:book) { |_id| book }
    api.define_singleton_method(:each_page_batch) do |_id, start:, &block|
      attempts += 1
      if attempts == 1
        started << true
        gate.pop
      end
      block.call((1..2).map { |number| { "id" => 1230 + number, "number" => number, "content" => "نص الكتاب الجديد" } })
    end
    get(:download_queue).enqueue(book)
    wait { !started.empty? }
    check("Move begins with a real active book download", get(:download_queue).current[:status] == :downloading)
  end

  def cancelled_relocation
    click(action(:settings))
    folder = File.join(Dir.home, "Cancelled move")
    FileUtils.mkdir_p(folder)
    picker(folder)
    click(action(:move_library))
    hold_transfer
    click(action(:confirm_library_move))
    wait { get(:library_move_fraction).positive? }
    activate(action(:cancel_library_move))
    @gate << true
    wait { !get(:library_moving) }
    check("Cancelled copy keeps original folder", get(:storage).directory == @destination && Dir.children(folder) == ["app.lock"])
    check("Cancelled copy resumes reading", get(:screen) == :reader && get(:reader)[:number] == 3 && get(:settings_message).include?("أُلغي"))
    @app.close_dialog
  ensure
    get(:storage).singleton_class.remove_method(:prepare) if get(:storage).singleton_methods.include?(:prepare)
  end

  def disconnected_drive
    # Rename models a removed mount. No replacement folder should be created.
    renamed = @destination + "-reconnected"
    storage = get(:storage)
    if Gem.win_platform?
      # Windows forbids renaming an open library; emulate drive removal before
      # changing its path so the real recovery flow closes all file handles.
      storage.define_singleton_method(:available?) { false }
      set(library_checked_at: nil)
      @app.tick
      storage.singleton_class.remove_method(:available?)
    end
    File.rename(@destination, renamed)
    set(library_checked_at: nil)
    @app.tick
    check("Disconnected drive blocks access", get(:library_unavailable) && get(:store).nil?)
    check("Disconnected path is not recreated", !File.exist?(@destination))
    shot("drive-unavailable")
    activate(action(:retry_library))
    check("Retry without drive preserves recovery screen", get(:library_unavailable))
    picker(Aljam3.data_directory)
    click(action(:locate_library))
    check("Wrong library is rejected", get(:library_unavailable) && get(:storage_error).include?("مكتبتك"))
    picker(renamed)
    activate(action(:locate_library))
    wait { !get(:library_unavailable) }
    check("New drive path reconnects same library", get(:storage).directory == renamed && get(:screen) == :reader && get(:reader)[:number] == 3)
    check("Bookmarks remain after reconnect", get(:store).bookmarks(@book.fetch("id")).length == 1)
    @destination = renamed
  end

  def move_back_to_default
    @app.navigate(:home)
    pending_book = @book.merge("id" => 999_999)
    gate = Queue.new
    get(:api).define_singleton_method(:book) { |_id| gate.pop; pending_book }
    set(connection: :online)
    @app.open_book(pending_book)
    check("Online book is still opening before relocation", get(:screen) == :opening)
    click(action(:settings))
    picker(Aljam3.data_directory)
    click(action(:move_library))
    click(action(:confirm_library_move))
    wait { !get(:library_moving) }
    check("Can move back to default folder", File.identical?(get(:storage).directory, Aljam3.data_directory))
    check("Default app lock survives moving back", !Aljam3::Instance.acquire(Aljam3.data_directory))
    check("Returned library still searches offline", get(:store).search("العلم").fetch("pages").length == 6)
    check("Moving during online opening returns to a usable catalog", get(:screen) == :home && !get(:busy))
  end
end
