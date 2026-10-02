# frozen_string_literal: true

# Executed by the bundled Ruby and launcher, with a scratch HOME and a headless renderer.
require "json"
root = ENV.fetch("ALJAM3_BUNDLE_ROOT")
output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
require File.join(root, "app/lib/aljam3")
require File.join(root, "app/lib/aljam3/pdf")
api = Aljam3::API.new
raise "Bundled HTTPS failed" if api.books.fetch("books").empty?
# Installer checks start with an empty library and download through the bundled runtime.
directory = Aljam3.data_directory
store = Aljam3::Store.new(File.join(directory, "library.sqlite3"))
begin
  Aljam3::Downloader.new(api:, store:, directory: File.join(directory, "books")).call(1)
  store.save_preference("theme", "light")
ensure
  store.close
end
load File.join(root, "app/app.rb")
app = Shoes.APPS.first
step = 0
pdf_bounds = pdf_pixels = nil
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
app.every(0.1) do
  begin
    raise "Package verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 45
    store = app.instance_variable_get(:@store)
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    case step
    when 0
      if app.instance_variable_get(:@screen) == :home
        app.navigate(:browse)
        next
      end
      next if app.instance_variable_get(:@busy)

      raise "Arabic tokenizer failed" if store.search("العلم").fetch("pages").empty?
      raise "Offline fallback failed" unless app.instance_variable_get(:@source) == :offline
      field = app.instance_variable_get(:@query_field)
      automation.click({ id: field.linkable_id })
      automation.type("آداب العلم")
      raise "Arabic input failed" unless field.text == "آداب العلم"
      app.open_book(store.book(1))
      app.turn_page(72)
      step = 1
    when 1
      next unless app.instance_variable_get(:@page_image)

      raise "Text missing" if app.page_text.strip.empty?
      app.copy_page
      raise "Arabic clipboard failed" unless app.clipboard == app.page_text
      image = app.instance_variable_get(:@page_image)
      raise "PDF rendering failed" unless File.file?(image.url)
      pdf = automation.rect_of!(app.instance_variable_get(:@pdf_surface).linkable_id)
      text = automation.rect_of!(app.instance_variable_get(:@text_surface).linkable_id)
      raise "Reader pane order is not RTL" unless text.x > pdf.x
      automation.wait_frames
      automation.snapshot(File.join(output, "reader.png"), scale: 2)
      bounds = automation.rect_of!(image.linkable_id)
      pdf_bounds = [bounds.x, bounds.y, bounds.w, bounds.h].map { |value| (value * 2).round }
      pdf_pixels = ChunkyPNG::Image.from_file(File.join(output, "reader.png")).crop(*pdf_bounds).pixels
      app.toggle_theme
      step = 2
    when 2
      next unless app.instance_variable_get(:@page_image)

      raise "Theme was not saved" unless store.preference("theme") == "dark"
      automation.wait_frames
      automation.snapshot(File.join(output, "reader-dark.png"), scale: 2)
      dark_pixels = ChunkyPNG::Image.from_file(File.join(output, "reader-dark.png")).crop(*pdf_bounds).pixels
      raise "PDF changed after switching themes" unless dark_pixels == pdf_pixels
      app.open_book_search
      app.instance_variable_get(:@book_search)[:query] = "العلم"
      app.request_book_search
      step = 3
    when 3
      next if app.instance_variable_get(:@book_search)[:busy]

      result = app.instance_variable_get(:@book_search).fetch(:result)
      raise "Book search failed" unless result.source == :offline && result.data.fetch("pages").any?
      automation.wait_frames
      automation.snapshot(File.join(output, "search.png"), scale: 2)
      app.close_dialog
      app.open_book(store.book(1), hit: result.data.fetch("pages").first, query: "العلم")
      step = 4
    when 4
      next unless app.instance_variable_get(:@page_image)

      reader = app.instance_variable_get(:@reader)
      count = Aljam3::Text.match_ranges(app.page_text, reader.fetch(:query)).length
      raise "Search highlights missing" unless count > 1
      automation.key("f3")
      raise "Match navigation failed" unless reader[:match_index] == 1
      automation.wait_frames
      automation.snapshot(File.join(output, "reader-matches.png"), scale: 2)
      text = automation.rect_of!(app.instance_variable_get(:@text_surface).linkable_id)
      bounds = [text.x, text.y, text.w, text.h].map { |value| (value * 2).round }
      colored = ChunkyPNG::Image.from_file(File.join(output, "reader-matches.png")).crop(*bounds).pixels.count(ChunkyPNG::Color.from_hex(app.primary))
      raise "Arabic highlight was not painted" unless colored > 100
      divider = automation.rect_of!(app.instance_variable_get(:@reader_divider).linkable_id)
      x, y = divider.center
      automation.mouse(:down, x, y)
      automation.mouse(:move, x - 90, y)
      automation.mouse(:up, x - 90, y)
      raise "Divider drag failed" unless reader[:split_ratio] < 0.45
      app.toggle_reader_bookmark unless app.bookmarked?
      app.open_dialog(:reader_options)
      tashkeel = reader[:tashkeel]
      label = tashkeel ? "إخفاء التشكيل" : "إظهار التشكيل"
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == label }
      raise "Tashkeel control missing" unless button
      automation.click({ id: button.fetch(:id) })
      raise "Tashkeel option failed" unless reader[:tashkeel] == !tashkeel
      automation.wait_frames
      automation.snapshot(File.join(output, "reading-options.png"), scale: 2)
      app.close_dialog
      reopened = Aljam3::Store.new(File.join(directory, "library.sqlite3"))
      begin
        raise "Reading history was not persisted" unless reopened.recent_books.first.fetch("number") == reader[:number]
        raise "Bookmark was not persisted" if reopened.bookmarks(1).empty?
        raise "Reader settings were not persisted" unless reopened.preference("reader").fetch("split_ratio") == reader[:split_ratio]
      ensure
        reopened.close
      end
      app.navigate(:home)
      automation.wait_frames
      automation.snapshot(File.join(output, "home.png"), scale: 2)
      app.navigate(:downloads)
      automation.wait_frames
      automation.snapshot(File.join(output, "downloads.png"), scale: 2)
      File.write(File.join(output, "passed.json"), JSON.pretty_generate({ passed: true, ruby: RUBY_VERSION,
        platform: RUBY_PLATFORM, build: JSON.parse(File.read(File.join(root, "build.json"))),
        checks: %w[https sqlite arabic_tokenizer offline_fallback arabic_input clipboard pdf text rtl_panes persistent_dark_theme pdf_theme_redraw book_search native_rendering arabic_highlight_pixels match_navigation draggable_divider reading_options persistent_history persistent_bookmarks persistent_reader_settings] }))
      app.close
    end
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
