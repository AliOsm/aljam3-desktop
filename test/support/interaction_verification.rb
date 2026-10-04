# frozen_string_literal: true

require "timeout"
require "socket"
require_relative "alignment_verification"

class InteractionVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks = []
    @store = get(:store)
  end

  def call
    @app.choose_motion("reduced")
    # Finish startup requests before replacing their catalog with the fixture.
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    Timeout.timeout(10) do
      until ready
        @app.tick
        sleep 0.01
      end
    end
    AlignmentVerification.seed(@store)
    @book = AlignmentVerification::BOOKS.first
    @text = ("العِلْم نورٌ وكتابٌ نافع. هذا نصٌّ عربيّ للاختيار والنسخ.\n" * 40).strip
    @store.add_pages(@book.fetch("id"), [{ "id" => 940_001, "number" => 2, "content" => @text }])
    @store.save_reading(@book.fetch("id"), file_id: @book.fetch("id"), number: 2)
    @store.save_preference("reader", { "mode" => "text" })
    set(categories: AlignmentVerification::CATEGORIES, libraries: AlignmentVerification::LIBRARIES, downloaded_ids: @store.downloaded_ids)
    selection_and_scroll
    scopes
    history
    pdf_controls
    exports
    { passed: true, checks: @checks }
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |name, value| @app.instance_variable_set("@#{name}", value) }
  def click(control) = @automation.click({ id: control.linkable_id })
  def action(key) = get(:action_views).fetch(key)
  def check(name, condition)
    raise name unless condition

    @checks << name
  end

  def settle
    Timeout.timeout(10) do
      loop do
        @app.tick
        @automation.wait_frames
        break unless get(:busy)

        sleep 0.01
      end
    end
  end

  def shot(name) = @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1.5)

  def selection_and_scroll
    @app.navigate(:home)
    @app.open_book(@book)
    @automation.wait_frames
    para = @automation.rect_of!(get(:page_text).linkable_id)
    @app.clipboard = "sentinel"
    @automation.mouse(:down, para.x + para.w - 3, para.y + 12)
    @automation.mouse(:move, para.x + para.w / 2, para.y + 60)
    @automation.mouse(:up, para.x + para.w / 2, para.y + 60)
    @automation.key("command_c")
    copied = @app.clipboard
    check("Arabic paragraph drag copies only a selected passage", !copied.empty? && copied != @text && @text.include?(copied))
    shot("arabic-selection")
    @automation.key("command_a")
    @automation.key("command_c")
    check("Select All and Copy retain Arabic diacritics and line breaks", @app.clipboard == @text)
    @automation.key("backspace")
    @automation.type("abc")
    check("Reading text stays read-only", @app.page_text == @text)
    surface = get(:text_surface)
    rect = @automation.rect_of!(surface.linkable_id)
    @automation.mouse(:down, rect.x + 5, rect.y + 10)
    @automation.mouse(:move, rect.x + 5, rect.y + 150)
    @automation.mouse(:up, rect.x + 5, rect.y + 150)
    check("The RTL reader scrollbar drags with the mouse", surface.scroll_top > 100)
    previous = surface.scroll_top
    @automation.mouse(:move, rect.x + 5, rect.y + 10)
    check("Releasing the thumb stops dragging", surface.scroll_top == previous)
    @automation.key("command_f")
    check("Find opens the book search while reader text has focus", get(:dialog)[:type] == :book_search)
    back
    check("Mouse Back closes an open popup before leaving the reader", !get(:dialog) && get(:screen) == :reader)
  end

  def scopes
    @app.browse_scope(:author, @book.fetch("author"))
    settle
    author_scope = { author: @book.dig("author", "id") }
    label = get(:scope_label)
    click(action(:filters))
    check("The author page identity cannot be accidentally replaced in filters", action([:filter, :author]).state == "disabled")
    click(action([:filter, :category]))
    check("The category refinement opens its choices", get(:dialog)&.dig(:type) == :choices)
    click(action(AlignmentVerification::CATEGORIES[1].fetch("name")))
    click(action("تطبيق"))
    settle
    both = author_scope.merge(category: @book.dig("category", "id"))
    check("Choosing a category preserves the author and page heading", get(:filters) == both && get(:scope_label) == label)
    @app.switch_search_mode(:content)
    settle
    check("Switching from title to text search preserves both scopes", get(:filters) == both && get(:scope_label) == label)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    @automation.key("enter")
    settle
    hits = get(:result).data.fetch("pages")
    check("Scoped offline text results belong to the author and category", !hits.empty? && hits.all? { |hit| hit.dig("book", "author", "id") == both[:author] && hit.dig("book", "category", "id") == both[:category] })
    @app.open_filters
    click(action("مسح التصفية"))
    click(action("تطبيق"))
    settle
    check("Clearing refinements keeps the author page scope", get(:filters) == author_scope && get(:scope_label) == label)
    shot("author-search-scope")
    @app.browse_scope(:category, @book.fetch("category"))
    settle
    @app.switch_search_mode(:content)
    settle
    check("Category pages retain their scope after changing search mode", get(:filters) == { category: @book.dig("category", "id") })
  end

  def back
    @automation.mouse(:down, 10, 100, button: 4)
    @automation.mouse(:up, 10, 100, button: 4)
    @automation.wait_frames
  end

  def forward
    @automation.mouse(:down, 10, 100, button: 5)
    @automation.mouse(:up, 10, 100, button: 5)
    @automation.wait_frames
  end

  def history
    @app.navigate(:home)
    @app.browse_scope(:author, @book.fetch("author"))
    settle
    set(query: "الجامع")
    @app.request_catalog
    settle
    expected = get(:result)
    @app.open_book(@book)
    @automation.wait_frames
    get(:text_surface).scroll_top = 200
    @automation.wait_frames
    back
    check("Mouse Back restores query, author scope, mode, and prior results", get(:screen) == :browse && get(:query) == "الجامع" && get(:filters) == { author: @book.dig("author", "id") } && get(:mode) == :books && get(:result) == expected)
    forward
    check("Mouse Forward restores the book, page, and text scroll", get(:screen) == :reader && get(:reader)[:number] == 2 && get(:text_surface).scroll_top == 200)
    @automation.key("alt_[")
    check("The standard Mac Back shortcut uses the same history", get(:screen) == :browse)
    @app.navigate(:categories)
    forward
    check("A new navigation clears the abandoned Forward path", get(:screen) == :categories)
    # A queued request must not redraw over a newer navigation.
    @app.navigate(:browse)
    @app.navigate(:home)
    30.times { @app.tick; sleep 0.01 }
    check("Stale catalog replies do not replace the newer page", get(:screen) == :home)
  end

  def pdf_controls
    @app.open_book(@book)
    image = Struct.new(:path, :width, :height).new(File.join(Aljam3::ROOT, "assets/brand/app-icon.png"), 1024, 1024)
    get(:reader).merge!(mode: :split, image: image)
    @app.draw_window
    check("Fit is disabled when the page is already fitted", get(:fit_button).state == "disabled")
    @app.define_singleton_method(:render_pdf) { draw_pdf_image }
    click(get(:zoom_in_button))
    check("Zooming enables Fit and retains its page-shaped icon", get(:reader)[:zoom] == 1.25 && get(:fit_button).state.nil? && get(:fit_button).icon.end_with?("page-fit.png"))
    click(get(:fit_button))
    check("Fit restores scale once and disables itself", get(:reader)[:zoom] == 1.0 && get(:fit_button).state == "disabled")
    shot("reader-fit-control")
    @automation.resize(420, 420)
    @app.tick
    @automation.wait_frames
    check("Resizing below the minimum keeps a usable reader", @app.width == 800 && @app.height == 600 && @app.reader_pane_widths.min >= 240)
    shot("reader-minimum-size")
    @automation.resize(1160, 820)
    @app.tick
  ensure
    @app.singleton_class.remove_method(:render_pdf) if @app.singleton_methods.include?(:render_pdf)
  end

  def exports
    folder = File.join(Aljam3.data_directory, "تصدير الكتب")
    FileUtils.mkdir_p(folder)
    captured = []
    @app.define_singleton_method(:ask_save_file) do |**options|
      captured << options
      File.join(folder, options.fetch(:filename))
    end
    bodies = { "pdf" => "%PDF-1.7\nexport fixture\n%%EOF", "txt" => @text, "docx" => "PK\x03\x04document fixture" }
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    transfer = Thread.new do
      bodies.size.times do
        socket = server.accept
        format = socket.gets.split[1].delete_prefix("/")
        while (header = socket.gets) && header != "\r\n"; end
        body = bodies.fetch(format).b
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
        socket.write(body)
        socket.close
      end
    end
    file = get(:reader).fetch(:file).merge("urls" => bodies.to_h { |format, _| [format, "http://127.0.0.1:#{port}/#{format}"] })
    bodies.each do |format, body|
      @app.export_file(file, format)
      wait_for_exports
      path = File.join(folder, captured.last.fetch(:filename))
      check("#{format.upcase} export keeps its suggested extension and exact bytes", File.extname(path) == ".#{format}" && File.binread(path) == body.b && captured.last[:extensions] == [format])
    end
    local = get(:downloader).pdf_path(@book.fetch("id"), file.fetch("id"))
    FileUtils.mkdir_p(File.dirname(local))
    File.binwrite(local, "%PDF-1.7\ndownloaded offline fixture\n%%EOF")
    offline_file = file.merge("urls" => { "pdf" => "http://127.0.0.1:1/unavailable.pdf" })
    @app.export_file(offline_file, "pdf")
    wait_for_exports
    path = File.join(folder, captured.last.fetch(:filename))
    check("A downloaded PDF can be exported while its server is unreachable", File.binread(path) == File.binread(local))
    @app.save_page_image
    wait_for_exports
    path = File.join(folder, captured.last.fetch(:filename))
    check("Page images are saved as valid PNG files", File.extname(path) == ".png" && File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b)
    check("Save dialogs request the expanded panel and remember the destination", captured.all? { |options| options[:expanded] } && captured.last[:directory] == folder)
  ensure
    server&.close
    transfer&.kill&.join
    @app.singleton_class.remove_method(:ask_save_file) if @app.singleton_methods.include?(:ask_save_file)
  end

  def wait_for_exports
    Timeout.timeout(10) do
      loop do
        @app.tick
        break unless get(:file_operations).values.any? { |job| job[:status] == :saving }

        sleep 0.01
      end
    end
  end
end
