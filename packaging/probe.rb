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
      automation.snapshot(File.join(output, "reader.png"), scale: 2)
      app.toggle_theme
      step = 2
    when 2
      next unless app.instance_variable_get(:@page_image)

      raise "Theme was not saved" unless store.preference("theme") == "dark"
      automation.snapshot(File.join(output, "reader-dark.png"), scale: 2)
      app.open_book_search
      app.instance_variable_get(:@book_search)[:query] = "العلم"
      app.request_book_search
      step = 3
    when 3
      next if app.instance_variable_get(:@book_search)[:busy]

      result = app.instance_variable_get(:@book_search).fetch(:result)
      raise "Book search failed" unless result.source == :offline && result.data.fetch("pages").any?
      automation.snapshot(File.join(output, "search.png"), scale: 2)
      File.write(File.join(output, "passed.json"), JSON.pretty_generate({ passed: true, ruby: RUBY_VERSION,
        platform: RUBY_PLATFORM, build: JSON.parse(File.read(File.join(root, "build.json"))),
        checks: %w[https sqlite arabic_tokenizer offline_fallback arabic_input clipboard pdf text rtl_panes persistent_dark_theme book_search native_rendering] }))
      app.close
    end
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
