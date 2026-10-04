# frozen_string_literal: true

# Live integration check: scratch library, native headless renderer, fake clipboard.
require "json"
load File.expand_path("../../app.rb", __dir__)
app = Shoes.APPS.first
app.choose_motion("reduced")
output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
step = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
hit = nil
library_id = nil
first_search_ids = nil
app.every(0.1) do
  begin
    raise "UI verification timed out at step #{step}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 105
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    shot = ->(name) do
      automation.wait_frames
      automation.snapshot(File.join(output, "#{name}.png"), scale: 2)
    end
    store = app.instance_variable_get(:@store)
    reader = app.instance_variable_get(:@reader)
    case step
    when 0
      app.instance_variable_set(:@theme, :light)
      app.apply_theme
      app.draw_window
      shot.call("home-first-use")
      field = app.instance_variable_get(:@query_field)
      automation.click({ id: field.linkable_id })
      automation.type("العلم والعمل")
      raise "Field focus is not tracked" unless app.instance_variable_get(:@editing_field) == field
      app.refresh_window
      raise "Background refresh interrupted typing" unless app.instance_variable_get(:@query_field) == field && field.text == "العلم والعمل"
      automation.key("tab")
      raise "Blur did not clear editing state" if app.instance_variable_get(:@editing_field)
      app.navigate(:home)
      app.open_book({ "id" => 1 })
      step = 1
    when 1
      raise "Opening the live book failed: #{app.instance_variable_get(:@error)}" if app.instance_variable_get(:@error)
      next unless app.instance_variable_get(:@screen) == :reader

      app.turn_page(72)
      step = 2
    when 2
      next unless app.instance_variable_get(:@page_image) && !reader[:loading_text]

      raise "Online text missing" if app.page_text.empty?
      raise "Online reading marked book as downloaded" if store.downloaded?(1)
      raise "Online reading polluted offline search" unless store.search("العلم").fetch("pages").empty?
      pdf = automation.rect_of!(app.instance_variable_get(:@pdf_surface).linkable_id)
      text = automation.rect_of!(app.instance_variable_get(:@text_surface).linkable_id)
      raise "Reader pane order is not RTL" unless text.x > pdf.x
      shot.call("reader-light")
      app.copy_page
      raise "Clipboard mismatch" unless app.clipboard == app.page_text
      app.toggle_theme
      automation.resize(800, 700)
      step = 3
    when 3
      next unless app.instance_variable_get(:@page_image)

      raise "Theme was not saved" unless store.preference("theme") == "dark"
      shot.call("reader-dark-compact")
      app.open_book_search
      field = app.instance_variable_get(:@book_query_field)
      automation.click({ id: field.linkable_id })
      automation.type("العلم")
      automation.key("enter")
      step = 4
    when 4
      search = app.instance_variable_get(:@book_search)
      next if search[:busy]

      result = search.fetch(:result)
      raise "Online book search failed" unless result.source == :online && result.data.fetch("pages").any?
      raise "Reader remains interactive under dialog" unless app.instance_variable_get(:@content_layer).style[:inert]
      shot.call("book-search")
      app.instance_variable_get(:@dialog_results).scroll_top = 180
      automation.wait_frames
      app.draw_window
      automation.wait_frames
      raise "Dialog results lost their scroll position" unless app.instance_variable_get(:@dialog_results).scroll_top == 180
      app.instance_variable_get(:@dialog_results).scroll_top = 0
      automation.wait_frames
      hit = result.data.fetch("pages").first
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "عرض الصفحة" }
      raise "Search result action missing" unless button

      automation.click({ id: button.fetch(:id) })
      step = 5
    when 5
      next unless app.instance_variable_get(:@screen) == :reader && !reader[:loading_text] && reader[:page]

      raise "Search opened the wrong page" unless reader.fetch(:page).fetch("id") == hit.fetch("id")
      raise "Search query lost" unless reader[:query] == "العلم"
      raise "Search matches missing" if Aljam3::Text.match_ranges(app.page_text, reader[:query]).empty?
      app.open_dialog(:export)
      shot.call("export")
      app.close_dialog
      app.browse_scope(:author, reader.fetch(:book).fetch("author"))
      step = 6
    when 6
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result)
      raise "Author browsing failed" unless result&.source == :online && result.data.fetch("books").any?
      author_id = reader.fetch(:book).dig("author", "id")
      raise "Wrong author scope" unless result.data.fetch("books").all? { |book| book.dig("author", "id") == author_id }
      shot.call("author-books")
      app.open_filters
      name = Aljam3::Text.plain(reader.fetch(:book).dig("author", "name"))[0, 40]
      raise "Selected author not shown" unless automation.layout.any? { |node| node[:kind] == "Button" && node[:text] == name }
      shot.call("filters")
      library = reader.fetch(:book).fetch("library")
      library_id = library.fetch("id")
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "الجميع" }
      automation.click({ id: button.fetch(:id) })
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == library.fetch("name") }
      automation.click({ id: button.fetch(:id) })
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "تطبيق" }
      automation.click({ id: button.fetch(:id) })
      step = 7
    when 7
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result)
      raise "Library filter failed" unless result && result.data.fetch("books").any?
      raise "Wrong library scope" unless result.data.fetch("books").all? { |book| book.dig("library", "id") == library_id }
      author_id = reader.fetch(:book).dig("author", "id")
      raise "Author scope was lost" unless result.data.fetch("books").all? { |book| book.dig("author", "id") == author_id }
      raise "Additional filter replaced the author page" unless app.instance_variable_get(:@filters) == { author: author_id, library: library_id }
      raise "Unexpected combined-filter source" unless result.source == :online || (result.source == :local && result.notice == 501)
      app.queue_download(reader.fetch(:book))
      app.navigate(:downloads)
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "إيقاف مؤقت" }
      automation.click({ id: button.fetch(:id) })
      raise "Pause action failed" unless app.instance_variable_get(:@download_queue).entry(1)&.fetch(:status) == :paused
      shot.call("downloads-paused")
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "متابعة التنزيل" }
      automation.click({ id: button.fetch(:id) })
      step = 8
    when 8
      next unless app.instance_variable_get(:@download_queue).entry(1)&.fetch(:status) == :done

      offline = Aljam3::API.new(base_url: "http://127.0.0.1:1", interval: 0)
      app.instance_variable_set(:@api, offline)
      app.instance_variable_set(:@library, Aljam3::Library.new(api: offline, store:))
      app.open_book(store.book(1))
      app.open_book_search
      app.instance_variable_get(:@book_search)[:query] = "العلم"
      app.request_book_search
      step = 9
    when 9
      search = app.instance_variable_get(:@book_search)
      next if search[:busy]

      result = search.fetch(:result)
      raise "Offline search failed" unless result.source == :offline && result.data.fetch("pages").any?
      automation.key("escape")
      raise "Escape did not close dialog" if app.instance_variable_get(:@dialog)
      shot.call("reader-offline")
      app.open_book(store.book(1), hit: result.data.fetch("pages").first, query: "العلم")
      step = 10
    when 10
      next unless app.instance_variable_get(:@page_image)

      count = Aljam3::Text.match_ranges(app.page_text, reader[:query]).length
      raise "Expected several matches for navigation" unless count > 1
      automation.key("f3")
      raise "Next match shortcut failed" unless reader[:match_index] == 1
      automation.key("shift_f3")
      raise "Previous match shortcut failed" unless reader[:match_index] == 0
      shot.call("reader-matches")
      text = automation.rect_of!(app.instance_variable_get(:@text_surface).linkable_id)
      bounds = [text.x, text.y, text.w, text.h].map { |value| (value * 2).round }
      pixels = ChunkyPNG::Image.from_file(File.join(output, "reader-matches.png")).crop(*bounds).pixels
      raise "Arabic highlight not painted" unless pixels.count(ChunkyPNG::Color.from_hex(app.primary)) > 100
      divider = automation.rect_of!(app.instance_variable_get(:@reader_divider).linkable_id)
      x, y = divider.center
      automation.mouse(:down, x, y)
      automation.mouse(:move, x - 70, y)
      automation.mouse(:up, x - 70, y)
      raise "Divider did not move" unless reader[:split_ratio] < 0.45
      raise "Divider ratio not saved" unless store.preference("reader").fetch("split_ratio") == reader[:split_ratio]
      automation.key("control_d")
      raise "Bookmark shortcut failed" unless app.bookmarked?
      app.open_dialog(:bookmarks)
      shot.call("bookmarks")
      app.close_dialog
      options_button = app.instance_variable_get(:@action_views).fetch("خيارات القراءة")
      anchor = automation.rect_of!(options_button.linkable_id)
      automation.click({ id: options_button.linkable_id })
      panel = automation.rect_of!(app.instance_variable_get(:@dialog_panel).linkable_id)
      raise "Options popup is detached from its trigger" unless (panel.y - anchor.y - anchor.h - 8).abs < 1
      raise "Options popup leaves the viewport" unless panel.x >= 16 && panel.y >= 16 && panel.x + panel.w <= 784 && panel.y + panel.h <= 684
      shot.call("reading-options")
      automation.key("escape")
      returned = app.instance_variable_get(:@action_views).fetch("خيارات القراءة")
      raise "Closing popup lost keyboard focus" unless automation.focused == returned.linkable_id
      menu_button = app.instance_variable_get(:@action_views).fetch("أدوات الكتاب")
      automation.click({ id: menu_button.linkable_id })
      shot.call("reader-menu")
      app.close_dialog
      page = reader[:number]
      automation.key("left")
      raise "Next page shortcut failed" unless reader[:number] == page + 1
      automation.key("right")
      raise "Previous page shortcut failed" unless reader[:number] == page
      raise "Reader header is missing" unless app.instance_variable_get(:@action_views).key?("الرئيسية")
      raise "Redundant Go button remains" if automation.layout.any? { |node| node[:kind] == "Button" && node[:text] == "اذهب" }
      field = app.instance_variable_get(:@page_field)
      automation.click({ id: field.linkable_id })
      automation.key("control_a")
      automation.type("٠")
      automation.key("enter")
      raise "Invalid page changed reading position" unless reader[:number] == page
      raise "Invalid page has no explanation" if app.instance_variable_get(:@page_feedback).text.empty?
      shot.call("page-validation")
      automation.key("control_a")
      automation.type(page.to_s.tr("0123456789", "٠١٢٣٤٥٦٧٨٩"))
      automation.key("enter")
      raise "Enter did not accept Arabic page digits" unless reader[:number] == page
      app.navigate(:home)
      raise "Recent reading missing" unless store.recent_books.first.fetch("number") == page
      shot.call("home-compact")
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "متابعة القراءة" }
      raise "Continue reading action missing" unless button
      automation.click({ id: button.fetch(:id) })
      raise "Continue reading opened wrong page" unless app.instance_variable_get(:@reader).fetch(:number) == page
      raise "Split ratio lost on reopen" unless app.instance_variable_get(:@reader).fetch(:split_ratio) == store.preference("reader").fetch("split_ratio")
      app.navigate(:home)
      app.toggle_theme
      automation.resize(1160, 820)
      step = 11
    when 11
      shot.call("home")
      app.navigate(:downloads)
      shot.call("downloads")
      app.navigate(:saved)
      app.instance_variable_set(:@query, "العلم")
      app.request_catalog
      step = 12
    when 12
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result)
      raise "Downloaded scope failed" unless result.source == :downloaded && result.data.fetch("pages").any?
      shot.call("downloaded-search")
      first_search_ids = result.data.fetch("pages").map { |row| row.fetch("id") }
      automation.wait_frames
      app.instance_variable_get(:@results).scroll_top = app.instance_variable_get(:@results).scroll_max
      automation.wait_frames
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "التالي" }
      automation.click({ id: button.fetch(:id) })
      step = 13
    when 13
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result).data
      raise "Pagination did not advance" unless result.dig("pagination", "current_page") == 2
      raise "Results accumulated across pages" if result.fetch("pages").length > Aljam3::Store::PAGE_SIZE
      raise "Result pages overlap" unless (first_search_ids & result.fetch("pages").map { |row| row.fetch("id") }).empty?
      automation.wait_frames
      app.instance_variable_get(:@results).scroll_top = app.instance_variable_get(:@results).scroll_max
      automation.wait_frames
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "السابق" }
      automation.click({ id: button.fetch(:id) })
      step = 14
    when 14
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result).data
      raise "Previous page changed" unless result.fetch("pages").map { |row| row.fetch("id") } == first_search_ids
      app.navigate(:browse)
      raise "Cached catalog not shown immediately" unless app.instance_variable_get(:@result)&.source == :cached
      raise "Catalog not refreshing in background" unless app.instance_variable_get(:@busy)
      app.confirm_remove_download(store.book(1))
      shot.call("remove-download")
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "إزالة النسخة" }
      automation.click({ id: button.fetch(:id) })
      step = 15
    when 15
      next if app.instance_variable_get(:@dialog)&.dig(:busy)
      raise "Removal failed: #{app.instance_variable_get(:@dialog).inspect}" if app.instance_variable_get(:@dialog)

      raise "Removed book still available offline" if store.downloaded?(1)
      raise "Removed book still in search" unless store.search("العلم").fetch("pages").empty?
      raise "Bookmarks lost after removal" if store.bookmarks(1).empty?
      raise "Reading history lost after removal" if store.recent_books.empty?
      File.write(File.join(output, "passed.json"), JSON.pretty_generate({ passed: true,
        checks: %w[online_reading_without_download rtl_panes clipboard persistent_dark_theme compact_layout modal_search exact_search_page author_browsing filter_popup_scoping download offline_search escape search_highlights match_navigation draggable_divider persistent_split bookmarks keyboard_paging continue_reading downloaded_scope bounded_pagination immediate_cached_catalog remove_download_preserves_history typing_during_background_refresh field_blur anchored_popup popup_focus_return reader_header page_validation enter_arabic_digits dialog_scroll_preserved] }))
      app.close
    end
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
