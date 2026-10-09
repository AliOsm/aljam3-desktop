# frozen_string_literal: true

require_relative "motion_preference"

require "timeout"
require_relative "alignment_verification"

# Real native input and real workers, with disposable data and controlled I/O.
class FeedbackVerification
  class Transfer
    attr_accessor :error, :remove_gate, :remove_error

    def initialize(store)
      @store, @finish = store, Queue.new
    end

    def call(id, check:)
      yield(0.4, "PDF", 40, 100)
      loop do
        check.call
        raise @error if @error
        break unless @finish.empty?

        sleep 0.001
      end
      @finish.pop
      @store.complete_download(id)
    end

    def finish = @finish << true
    def repair_download_sizes(after: 0) = nil
    def remove(id)
      @remove_gate&.pop
      raise @remove_error if @remove_error

      @store.discard_download(id)
    end
  end

  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks, @now = [], 0.0
    @store = get(:store)
  end

  def call
    MotionPreference.set(@app, reduced: true) # Static checks; motion has its own timed interaction probe.
    get(:ticker).remove
    @app.tick
    AlignmentVerification.seed(@store)
    set(categories: AlignmentVerification::CATEGORIES, libraries: AlignmentVerification::LIBRARIES)
    @notices = Aljam3::Notifications.new(clock: -> { @now })
    get(:download_queue).close
    @transfer = Transfer.new(@store)
    @queue = Aljam3::Downloads.new(store: @store, downloader: @transfer) { |entry| @app.notify_download(entry) }
    set(notifications: @notices, download_queue: @queue, theme: :light, downloaded_ids: @store.downloaded_ids)
    @app.apply_theme
    inline_feedback
    notice_interactions
    downloads
    removal
    exports
    cache_feedback
    appearances
    { passed: true, checks: @checks }
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |name, value| @app.instance_variable_set("@#{name}", value) }
  def click(control) = @automation.click({ id: control.linkable_id })

  def check(name, condition)
    raise name unless condition

    @checks << name
  end

  def shot(name)
    @automation.wait_frames
    @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1.5)
  end

  def pump_until(timeout: 5)
    Timeout.timeout(timeout) do
      loop do
        @app.tick
        @automation.wait_frames
        break if yield

        sleep 0.005
      end
    end
  end

  def advance(seconds, **options)
    @now += seconds
    @notices.tick(**options)
    @app.update_notification
    @automation.wait_frames
  end

  def clear_notices
    @notices.dismiss while @notices.current
    @app.update_notification
  end

  def reader(book = AlignmentVerification::BOOKS.first)
    set(screen: :reader, results: nil, dialog: nil, bookmarks: @store.bookmarks(book.fetch("id")),
      reader: { book:, files: book.fetch("files"), file: book.fetch("files").first, number: 1,
        zoom: 1.0, mode: :text, text_size: 21, tashkeel: true, split_ratio: 0.5, query: "",
        page: { "content" => ("آدابُ الْعِلْمِ وأَهْلِهِ\n" * 100) } })
    @app.draw_window
    @automation.wait_frames
  end

  def inline_feedback
    @app.navigate(:home)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    get(:api).instance_variable_set(:@connection, :offline)
    @app.tick
    check("offline status updates without interrupting typing or adding a notice",
      get(:query_field).equal?(field) && @automation.focused == field.linkable_id && field.text == "العلم" &&
        get(:connection_text).text.include?("دون اتصال") && !@notices.current)
    reader
    surface = get(:text_surface)
    surface.scroll_top = 180
    copy = get(:copy_button)
    click(copy)
    check("copy confirms on its own control", copy.style[:tooltip] == "تم النسخ" && !@notices.current)
    check("copy writes through the fake clipboard", @app.clipboard.include?("آدابُ"))
    @automation.advance(2.1)
    check("copy feedback resets", copy.style[:tooltip] == "نسخ نص الصفحة")
    bookmark = get(:bookmark_button)
    click(bookmark)
    check("bookmark updates in place with an accessible toggled state", @app.bookmarked? && bookmark.style[:toggled] &&
      get(:text_surface).equal?(surface) && surface.scroll_top == 180 && @automation.focused == bookmark.linkable_id)
    @automation.key("control_d")
    check("bookmark shortcut removes it quietly", !@app.bookmarked? && !bookmark.style[:toggled] && !@notices.current)
    @app.open_dialog(:share)
    copy_link = get(:action_views).fetch("نسخ الرابط")
    click(copy_link)
    check("link copy changes the button text and keeps the white icon", copy_link.text == "تم النسخ" &&
      copy_link.style[:icon].end_with?("check-dark.png") && !@notices.current)
    @app.close_dialog
  end

  def notice_interactions
    @app.navigate(:home)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    @automation.key("right")
    @app.notify_download(book: AlignmentVerification::BOOKS.first, status: :done)
    @app.update_notification
    @automation.type("أ")
    check("notices preserve the text caret and input object", field.text == "العلأم" && get(:query_field).equal?(field) &&
      @automation.focused == field.linkable_id)
    @automation.hover(get(:notification_layer).linkable_id)
    check("notice hover is tracked", get(:notification_hover))
    @now += 20
    @app.tick_feedback
    check("hover pauses the notice lifetime", !!@notices.current)
    @automation.leave(get(:notification_layer).linkable_id)
    close = get(:action_views).fetch([:notification, :close])
    close.focus
    @automation.wait_frames
    @now += 20
    @app.tick_feedback
    check("keyboard focus pauses the notice lifetime", get(:notification_focus) && !!@notices.current)
    @automation.key("space")
    check("dismissing a notice restores content focus", !@notices.current && @automation.focused == field.linkable_id)
    @app.open_dialog(:shortcuts)
    focused = @automation.focused
    @app.notify_download(book: AlignmentVerification::BOOKS.first, status: :done)
    @now += 100
    @app.tick_feedback
    check("notices wait for dialogs without stealing focus", !!@notices.current && !get(:notification_view) && @automation.focused == focused)
    @app.close_dialog
    check("waiting notice appears after the dialog closes", !!get(:notification_view))
    advance(5)
    check("success expires once visible", !@notices.current)
  end

  def downloads
    @book = Marshal.load(Marshal.dump(AlignmentVerification::BOOKS.first))
    @book["id"] = 920_000
    @book["files"].first["id"] = 920_000
    @store.prepare_download(@book)
    reader(@book)
    @app.open_dialog(:export)
    button = get(:export_download_button)
    click(button)
    check("download click immediately confirms it is queued", button.text == "في قائمة التنزيل" && button.style[:state] == "disabled")
    check("duplicate downloads are ignored", !@queue.enqueue(@book))
    pump_until { @queue.current&.fetch(:fraction) == 0.4 }
    check("download progress changes without recreating the dialog", get(:export_download_button).equal?(button) &&
      get(:export_download_progress).fraction == 0.4 && get(:activity_button).text.include?("40%"))
    shot("download-progress")
    @automation.resize(800, 700)
    @app.tick
    @automation.wait_frames
    controls = %i[connection_text reconnect_button activity_button activity_progress].map { |name| @automation.rect_of!(get(name).linkable_id) }
    check("compact footer fits connection, reconnect, and download progress", controls.all? { |box| box.x >= 24 && box.x + box.w <= 776 && box.y + box.h <= 700 })
    shot("download-progress-compact")
    @automation.resize(1160, 820)
    @app.tick
    @app.close_dialog
    field = get(:page_field)
    click(field)
    @automation.key("control_a")
    @automation.type("12")
    @transfer.error = Aljam3::ConnectionError.new("test offline")
    pump_until(timeout: 15) { @queue.entry(@book.fetch("id"))[:status] == :failed }
    check("download failure preserves editing and refreshes footer counts", get(:page_field).equal?(field) && field.text == "12" &&
      @automation.focused == field.linkable_id && get(:activity_button).text.include?("تنزيل يحتاج") && @notices.current[:error])
    advance(100)
    check("actionable failure remains visible", @notices.current[:key] == :download_failed)
    shot("download-failed")
    @transfer.error = nil
    click(get(:action_views).fetch([:notification, :action]))
    check("retry restores the reader focus", @automation.focused == field.linkable_id)
    @transfer.finish
    pump_until { @queue.entry(@book.fetch("id"))[:status] == :done }
    check("retry completes and clears active download state", @notices.current[:key] == :download_done && get(:download_states).empty?)
    @app.notify_download(book: AlignmentVerification::BOOKS.last, status: :done)
    @app.update_notification
    check("several completed books share one compact notice", @notices.current[:count] == 2 && get(:notice_action).text == "عرض التنزيلات")
    clear_notices
    books = AlignmentVerification::BOOKS.first(2)
    books.each { |book| @app.notify_download(book:, status: :failed, message: "تعذّر الاتصال") }
    @app.resolve_download_failure(books.first.fetch("id"))
    check("resolved failures leave only the remaining book in the notice", @notices.current[:count] == 1 &&
      @notices.current.fetch(:downloads).first.fetch(:book).fetch("id") == books.last.fetch("id"))
    @app.resolve_download_failure(books.last.fetch("id"))
    check("resolved failure notices disappear", !@notices.current)
  end

  def exports
    reader
    @app.open_dialog(:export)
    @app.define_singleton_method(:ask_save_file) { |**_options| nil }
    @app.export_file(get(:reader).fetch(:file), "pdf")
    @app.singleton_class.remove_method(:ask_save_file)
    check("cancelling the save chooser starts no job", get(:file_operations).empty? && !@notices.current)
    gate = Queue.new
    path = File.join(Aljam3.data_directory, "كتاب العلم.txt")
    @app.save_file([910_000, "txt"], path:, book_id: 910_000) { gate.pop; File.write(path, "العلم") }
    job = get(:file_operations).fetch([910_000, "txt"])
    @app.save_file([910_000, "txt"], path:, book_id: 910_000) { raise "Duplicate export ran" }
    check("repeated save requests retain one job", get(:file_operations).fetch([910_000, "txt"]).equal?(job))
    check("saving has immediate inline feedback", get(:export_feedback).text == "جارٍ حفظ الملف…")
    @app.close_dialog
    check("saving remains visible in the footer after closing the dialog", get(:file_activity_label).text.include?("جارٍ حفظ"))
    gate << true
    pump_until { @notices.find(:export_done) }
    check("export completion is retained after the dialog closes", File.read(path) == "العلم" && @notices.current[:key] == :export_done)
    clear_notices
    @app.open_dialog(:export)
    attempts = 0
    @app.save_file([910_000, "pdf"], path:, book_id: 910_000) do
      attempts += 1
      raise Errno::ENOSPC if attempts == 1

      File.write(path, "retried")
    end
    pump_until { @notices.find(:export_failed) }
    check("export errors update the dialog and wait behind it", get(:export_feedback).text.include?("مساحة") && !get(:notification_view))
    @app.close_dialog
    @app.open_dialog(:export)
    check("reopened export dialog remembers the failure", get(:export_feedback).text.include?("مساحة"))
    @app.close_dialog
    click(get(:action_views).fetch([:notification, :action]))
    pump_until { @notices.find(:export_done) }
    check("export retry saves the selected file", attempts == 2 && File.read(path) == "retried")
    clear_notices
    @app.notify_file_failure([job.merge(status: :failed, message: "تعذّر الحفظ")])
    @app.save_file([910_000, "txt"], path:, book_id: 910_000) { File.write(path, "saved again") }
    check("retrying from the export dialog also clears the old error notice", !@notices.find(:export_failed))
    pump_until { @notices.find(:export_done) }
    clear_notices
  end

  def removal
    @app.navigate(:saved)
    pump_until { !get(:busy) }
    check("The completed book appears in the saved library before removal",
      get(:result).data.fetch("books").any? { |book| book.fetch("id") == @book.fetch("id") })
    @transfer.remove_gate = gate = Queue.new
    @app.confirm_remove_download(@book)
    click(get(:action_views).fetch("إزالة النسخة"))
    @app.close_dialog
    finished = false
    get(:export_worker).submit(-> { true }) { finished = true }
    gate << true
    pump_until { finished && !get(:busy) }
    check("Removal still reports completion after its dialog was dismissed", !!@notices.find(:removed))
    check("A dismissed removal refreshes the saved library",
      get(:result).data.fetch("books").none? { |book| book.fetch("id") == @book.fetch("id") })
    clear_notices

    @store.prepare_download(@book)
    @queue.enqueue(@book)
    @transfer.finish
    @app.refresh_download_state
    pump_until { @store.downloaded?(@book.fetch("id")) && !get(:busy) && get(:result).data.fetch("books").any? { |book| book.fetch("id") == @book.fetch("id") } }
    check("A newly completed download refreshes the visible saved library", true)
    clear_notices
    @app.navigate(:home)
    @transfer.remove_error = Errno::EACCES.new("test PDF is busy")
    @app.confirm_remove_download(@book)
    click(get(:action_views).fetch("إزالة النسخة"))
    @app.close_dialog
    gate << true
    failure_key = [:remove_failed, @book.fetch("id")]
    pump_until { @notices.find(failure_key) }
    check("Removal failures remain actionable after dismissing the dialog", @store.downloaded?(@book.fetch("id")))
    @transfer.remove_error = nil
    @transfer.remove_gate = nil
    click(get(:action_views).fetch([:notification, :action]))
    click(get(:action_views).fetch("إزالة النسخة"))
    pump_until { @notices.find(:removed) && !get(:busy) }
    check("Retrying removal clears the error and removes the book", !@notices.find(failure_key) && !@store.downloaded?(@book.fetch("id")))
    clear_notices
    @app.navigate_history(:back)
    pump_until { !get(:busy) }
    check("Returning to the saved library does not restore a removed book from history",
      get(:screen) == :saved && get(:result).data.fetch("books").none? { |book| book.fetch("id") == @book.fetch("id") })
  ensure
    @transfer.remove_gate = nil
    @transfer.remove_error = nil
    gate << true if gate
  end

  def cache_feedback
    directory = File.join(Aljam3.data_directory, "renders")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "temporary.png"), "x" * 2048)
    @app.navigate(:downloads)
    click(get(:clear_cache_button))
    pump_until { !get(:clearing_cache) }
    check("cache feedback reports actual space freed inline", get(:storage_feedback).include?("2.0 KB") && !@notices.current)
  end

  def appearances
    %i[light dark].each do |theme|
      set(theme:)
      @app.apply_theme
      [[1160, 820], [800, 700]].each do |width, height|
        @automation.resize(width, height)
        reader
        @app.notify_download(book: AlignmentVerification::BOOKS.first, status: :done)
        @app.update_notification
        @automation.wait_frames
        panel = @automation.rect_of!(get(:notification_layer).linkable_id)
        check("#{theme} #{width}: notice fits above reader navigation", panel.x >= 24 && panel.x + panel.w <= width - 24 &&
          panel.y + panel.h <= height - 120)
        shot("complete-#{theme}-#{width}")
        clear_notices
      end
    end
  end
end
