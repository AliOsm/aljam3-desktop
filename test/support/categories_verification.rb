# frozen_string_literal: true

require "timeout"
require_relative "motion_preference"
require_relative "category_server"

class CategoriesVerification
  def initialize(app, automation, output:)
    @app, @automation, @output, @checks = app, automation, output, []
  end

  def call
    MotionPreference.set(@app, reduced: true)
    get(:ticker).remove
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    wait { ready }
    @server = CategoryServer.new
    @category = @server.category
    @id = @category.fetch("id")
    @store = get(:store)
    api = Aljam3::API.new(base_url: @server.base, interval: 0)
    downloader = Aljam3::Downloader.new(api:, store: @store, directory: File.join(Aljam3.data_directory, "books"))
    get(:download_queue).close
    queue = Aljam3::Downloads.new(store: @store, downloader:) { |entry| @app.notify_download(entry) }
    set(api:, library: Aljam3::Library.new(api:, store: @store), downloader:, download_queue: queue,
      categories: [@category], libraries: [], theme: :light)
    @app.apply_theme
    @server.books.first(2).each { |book| downloader.call(book.fetch("id")) }
    @server.hold_file = file_id(3)
    queue.enqueue(@server.books[2])
    @app.refresh_download_state
    @app.browse_scope(:category, @category)
    wait { !get(:busy) && queue.current&.fetch(:bytes, nil) }
    shot("category-page-light")
    check("Category pages expose the download action beside their heading", get(:action_views).key?(:download_category))

    @server.hold_scan_page = 2
    click(:download_category)
    wait { get(:category_scan_label).text.include?("6 / 18") }
    shot("preparing-category")
    @app.close_dialog
    @server.hold_scan_page = nil
    ready = false
    get(:category_worker).submit(-> { nil }) { ready = true }
    wait { ready }
    check("Closing preparation queues no books and creates no category", @store.category_downloads.empty? && @store.download_state_counts.values.sum == 1)

    set(query: "لا يوجد عنوان مطابق")
    @app.request_catalog
    wait { !get(:busy) }
    check("The fixture search has no results", get(:result).data.fetch("books").empty?)
    click(:download_category)
    wait { !get(:dialog)[:busy] }
    preview = get(:dialog).fetch(:preview)
    check("Confirmation covers every category page despite the current search", preview.slice(:total, :done, :existing, :new) == { total: 18, done: 2, existing: 1, new: 15 })
    check("Preparation only requests category listings at the bulk page size", @server.requests.count { |path| path.include?("limit=500") } >= 3)
    @app.close_dialog
    set(query: "")
    @app.request_catalog
    wait { !get(:busy) }
    click(:download_category)
    wait { !get(:dialog)[:busy] }
    shot("confirmation-light")
    @app.toggle_theme
    shot("confirmation-dark")
    @automation.resize(800, 600)
    @app.draw_window
    @automation.wait_frames
    panel = @automation.rect_of!(get(:dialog_panel).linkable_id)
    check("The confirmation stays compact at minimum window size", panel.h == 244 && panel.y >= 16 && panel.y + panel.h <= 584)
    shot("confirmation-compact-dark")

    @server.hold_file = file_id(4)
    click(:start_category_download)
    wait { get(:screen) == :downloads && queue.current&.dig(:book, "id") == book_id(4) && queue.current[:bytes] }
    check("One category group owns only the fifteen new books", group[:total] == 15 && @store.downloads(ungrouped: true).length == 3)
    check("The group starts after the independent queued book", @store.downloaded?(book_id(3)))
    get(:notifications).dismiss(:download_done)
    @app.update_notification
    shot("downloading-compact-dark")
    @automation.resize(1160, 820)
    @app.draw_window
    shot("downloading-dark")
    @app.toggle_theme
    shot("downloading-light")
    click([:category_details, @id])
    @automation.wait_frames
    check("Expanded details are bounded to one page of books", get(:category_book_labels).length == Aljam3::Store::PAGE_SIZE)
    shot("expanded-books-light")
    results = get(:results)
    results.scroll_top = results.scroll_max
    @automation.wait_frames
    click("التالي")
    @automation.wait_frames
    check("Expanded category details reach the remaining books through pagination", get(:category_book_labels).length == 3 && get(:category_book_labels).key?(book_id(18)))
    results = get(:results)
    results.scroll_top = 0
    @automation.wait_frames
    click([:category_details, @id])
    click([:pause_category, @id])
    @server.hold_file = nil
    wait { group[:paused] == 15 }
    shot("paused-light")
    queue.close
    queue = Aljam3::Downloads.new(store: @store, downloader:) { |entry| @app.notify_download(entry) }
    set(download_queue: queue)
    @app.refresh_download_state
    @app.tick
    check("Paused category downloads remain paused after restarting the queue", group[:paused] == 15 && !queue.current)

    @server.failed_files << file_id(5)
    @server.hold_file = file_id(6)
    click([:resume_category, @id])
    wait { group[:done] == 1 && group[:failed] == 1 && queue.current&.dig(:book, "id") == book_id(6) && queue.current[:bytes] }
    check("A failed book does not stop later category downloads", group[:queued] == 12)
    check("A completed multi-volume book is already searchable while the category continues",
      @store.files(book_id(4)).length == 2 && @store.search("العلم", book_id: book_id(4)).fetch("pages").length == 4)
    shot("partial-failure-light")
    click([:pause_category, @id])
    @server.hold_file = nil
    wait { group[:paused] == 13 }
    @server.failed_files.clear
    @server.hold_file = file_id(5)
    click([:retry_category, @id])
    wait { queue.current&.dig(:book, "id") == book_id(5) && queue.current[:bytes] }
    check("Retry failed books leaves the other paused books paused", group[:paused] == 13 && group[:queued].zero?)
    @server.hold_file = nil
    wait { group[:done] == 2 && !queue.current }
    click([:cancel_category, @id])
    wait { group[:cancelled] == 13 && get(:action_views).key?([:resume_category, @id]) }
    check("Cancellation keeps completed category books and independent downloads", @store.downloaded_ids.length == 5 && @store.downloaded?(book_id(3)))
    shot("cancelled-light")
    click([:resume_category, @id])
    wait { group[:done] == 15 && !queue.current }
    check("Resuming a cancelled category completes the missing books", @store.downloaded_ids.length == 18)
    check("Every completed book has both its PDFs and searchable text",
      @server.books.all? { |book| book.fetch("files").all? { |file| File.file?(downloader.pdf_path(book.fetch("id"), file.fetch("id"))) && @store.page_count(file.fetch("id")) == 2 } })
    check("Category completion emits a single category notification", get(:notifications).find([:category_download, @id])&.fetch(:message) == "اكتمل تنزيل التصنيف")
    shot("completed-light")
    @app.prepare_category_download(@category)
    wait { !get(:dialog)[:busy] }
    check("Repeating a completed category offers no duplicate downloads", get(:dialog).dig(:preview, :new).zero? && @store.download_count == 18)
    shot("already-downloaded")
    @app.close_dialog
    @server.scan_error = true
    @app.prepare_category_download(@category)
    wait { !get(:dialog)[:busy] }
    check("A listing failure has a retry action and never starts a partial category", !!get(:dialog)[:error] && !get(:dialog)[:preview] && @store.download_count == 18)
    { passed: true, checks: @checks }
  ensure
    @server&.close
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |name, value| @app.instance_variable_set("@#{name}", value) }
  def group = @store.category_downloads.find { |item| item[:category_id] == @id }
  def book_id(number) = @server.books.fetch(number - 1).fetch("id")
  def file_id(number) = @server.books.fetch(number - 1).fetch("files").first.fetch("id")
  def click(key) = @automation.click({ id: get(:action_views).fetch(key).linkable_id })
  def check(label, result)
    raise label unless result

    @checks << label
  end
  def shot(name)
    @automation.wait_frames
    @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1.5)
  end
  def wait
    Timeout.timeout(20) do
      loop do
        @app.tick
        @automation.wait_frames
        break if yield

        sleep 0.005
      end
    end
  end
end
