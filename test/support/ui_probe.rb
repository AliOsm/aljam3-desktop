# frozen_string_literal: true

# Live integration check: scratch library, native headless renderer, fake clipboard.
require "json"
load File.expand_path("../../app.rb", __dir__)
app = Shoes.APPS.first
output = ENV.fetch("ALJAM3_VERIFY_OUTPUT")
step = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
hit = nil
library_id = nil
app.every(0.1) do
  begin
    raise "UI verification timed out at step #{step}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 105
    automation = Scarpe::Native::Automation.new(Shoes::DisplayService.display_service)
    store = app.instance_variable_get(:@store)
    reader = app.instance_variable_get(:@reader)
    case step
    when 0
      app.instance_variable_set(:@theme, :light)
      app.apply_theme
      app.open_book({ "id" => 1 })
      step = 1
    when 1
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
      automation.snapshot(File.join(output, "reader-light.png"), scale: 2)
      app.copy_page
      raise "Clipboard mismatch" unless app.clipboard == app.page_text
      app.toggle_theme
      automation.resize(800, 700)
      step = 3
    when 3
      next unless app.instance_variable_get(:@page_image)

      raise "Theme was not saved" unless store.preference("theme") == "dark"
      automation.snapshot(File.join(output, "reader-dark-compact.png"), scale: 2)
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
      raise "Reader remains interactive under dialog" unless app.instance_variable_get(:@page_field).state == "disabled"
      automation.snapshot(File.join(output, "book-search.png"), scale: 2)
      hit = result.data.fetch("pages").first
      button = automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "عرض الصفحة" }
      raise "Search result action missing" unless button

      automation.click({ id: button.fetch(:id) })
      step = 5
    when 5
      next unless app.instance_variable_get(:@screen) == :reader && !reader[:loading_text] && reader[:page]

      raise "Search opened the wrong page" unless reader.fetch(:page).fetch("id") == hit.fetch("id")
      app.open_dialog(:export)
      automation.snapshot(File.join(output, "export.png"), scale: 2)
      app.close_dialog
      app.browse_scope(:author, reader.fetch(:book).fetch("author"))
      step = 6
    when 6
      next if app.instance_variable_get(:@busy)

      result = app.instance_variable_get(:@result)
      raise "Author browsing failed" unless result&.source == :online && result.data.fetch("books").any?
      author_id = reader.fetch(:book).dig("author", "id")
      raise "Wrong author scope" unless result.data.fetch("books").all? { |book| book.dig("author", "id") == author_id }
      automation.snapshot(File.join(output, "author-books.png"), scale: 2)
      app.open_filters
      name = Aljam3::Text.plain(reader.fetch(:book).dig("author", "name"))[0, 40]
      raise "Selected author not shown" unless automation.layout.any? { |node| node[:kind] == "Button" && node[:text] == name }
      automation.snapshot(File.join(output, "filters.png"), scale: 2)
      library = app.instance_variable_get(:@libraries).first
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
      raise "Library filter failed" unless result&.source == :online && result.data.fetch("books").any?
      raise "Wrong library scope" unless result.data.fetch("books").all? { |book| book.dig("library", "id") == library_id }
      raise "Title scopes were combined" unless app.instance_variable_get(:@filters) == { library: library_id }
      app.queue_download(reader.fetch(:book))
      step = 8
    when 8
      next unless app.instance_variable_get(:@downloads).dig(1, :status) == :done

      offline = Aljam3::API.new(base_url: "http://127.0.0.1:1", interval: 0)
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
      automation.snapshot(File.join(output, "reader-offline.png"), scale: 2)
      File.write(File.join(output, "passed.json"), JSON.pretty_generate({ passed: true,
        checks: %w[online_reading_without_download rtl_panes clipboard persistent_dark_theme compact_layout modal_search exact_search_page author_browsing filter_sheet_scoping download offline_search escape] }))
      app.close
    end
  rescue StandardError => error
    File.write(File.join(output, "failed.txt"), error.full_message)
    warn error.full_message
    app.close
  end
end
