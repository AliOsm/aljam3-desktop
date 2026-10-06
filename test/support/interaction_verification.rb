# frozen_string_literal: true

require_relative "motion_preference"

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
    MotionPreference.set(@app, reduced: true)
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
    page_number_input
    scopes
    history
    pdf_controls
    exports
    text_lifecycle
    feedback_timer_lifecycle
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
        break unless get(:busy) || get(:dialog)&.dig(:busy)

        sleep 0.01
      end
    end
  end

  def shot(name) = @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1.5)

  def text_lifecycle
    service = Shoes::DisplayService.display_service
    registry = service.instance_variable_get(:@display_drawable_for)
    baseline = registry.size
    paragraph = fragment = link = nil
    slot = @app.stack do
      link = @app.link("رابط") { }
      fragment = @app.span(link)
      paragraph = @app.para(fragment)
    end
    text_id = paragraph.linkable_id
    service.receive("t" => "para_hit", "id" => text_id, "value" => 3)
    Shoes::DisplayService.para_cursor_top_cache[text_id] = 12
    paragraph.replace(fragment, " نص")
    check("Replacing text preserves fragments still in use", !fragment.destroyed && !link.destroyed)
    paragraph.replace("نص جديد")
    check("Replacing app text releases old nested fragments and links", fragment.destroyed && link.destroyed)
    reusable = nil
    slot.append do
      reusable = @app.span("نص قابل لإعادة الاستخدام")
      paragraph = @app.para(reusable, owns_text: false)
    end
    paragraph.remove
    check("Paragraphs can opt out of fragment ownership for reuse", !reusable.destroyed)
    slot.append { @app.para(reusable) }
    slot.clear
    check("A reused fragment is released by its new owning paragraph", reusable.destroyed)
    20.times do
      slot.clear { @app.para(@app.span(@app.link("رابط آخر") { })) }
    end
    slot.remove
    @automation.wait_frames
    check("Repeated rich-text rebuilds leave no registered drawables", registry.size == baseline)
    check("Removing paragraphs clears their hit and caret metadata", !Shoes::DisplayService.para_hit_cache.key?(text_id) && !Shoes::DisplayService.para_cursor_top_cache.key?(text_id))
    service.receive("t" => "layout", "rects" => [[slot.linkable_id, 0, 0, 100, 100, 100]])
    check("Late layout replies cannot restore removed views to the geometry cache", !Shoes::DisplayService.layout_cache.key?(slot.linkable_id))
    service.receive("t" => "para_hit", "id" => text_id, "value" => 5)
    check("Late hit-test replies cannot restore removed paragraph metadata", !Shoes::DisplayService.para_hit_cache.key?(text_id))
  end

  def feedback_timer_lifecycle
    wait_for_copy_feedback
    service = Shoes::DisplayService.display_service
    registry = service.instance_variable_get(:@display_drawable_for)
    timers = -> { registry.values.count { |item| item.kind == "SubscriptionItem" && item.props["shoes_api_name"] == "timer" } }
    baseline = timers.call
    control = @app.action("نسخ") { }
    20.times { @app.copy_with_feedback("نص", control:, label: "نسخ") }
    wait_for_copy_feedback
    check("Repeated copy feedback releases completed one-shot timers", timers.call == baseline)
    control.remove
  end

  def wait_for_copy_feedback
    service = Shoes::DisplayService.display_service
    Timeout.timeout(5) do
      while get(:copy_receipts)&.any?
        @automation.wait_frames
        service.pump.step(0.02)
      end
    end
  end

  def selection_and_scroll
    @app.navigate(:home)
    @app.open_book(@book)
    @automation.wait_frames
    para = @automation.rect_of!(get(:page_text).linkable_id)
    @app.clipboard = "sentinel"
    @automation.click({ x: para.x + para.w - 3, y: para.y + 12 }, button: 3)
    check("Right-click without a selection leaves the reader and clipboard unchanged", !get(:dialog) && @app.clipboard == "sentinel")
    @automation.mouse(:down, para.x + para.w - 3, para.y + 12)
    @automation.mouse(:move, para.x + para.w / 2, para.y + 60)
    @automation.mouse(:up, para.x + para.w / 2, para.y + 60)
    @automation.key("command_c")
    copied = @app.clipboard
    check("Arabic paragraph drag copies only a selected passage", !copied.empty? && copied != @text && @text.include?(copied))
    shot("arabic-selection")
    @app.clipboard = "sentinel"
    @automation.click({ x: para.x + para.w / 2, y: para.y + 60 }, button: 3)
    check("Right-click opens a copy menu without changing the selection or clipboard", get(:dialog)&.dig(:type) == :reader_copy && get(:page_text).selected_text == copied && @app.clipboard == "sentinel")
    shot("reader-copy-menu")
    click(action(:copy_selection))
    @automation.wait_frames
    check("The reader context menu copies exactly the selected Arabic text", @app.clipboard == copied && !get(:dialog))
    check("Closing the copy menu restores paragraph focus and selection", @automation.focused == get(:page_text).linkable_id && get(:page_text).selected_text == copied)
    @automation.click({ x: para.x + para.w / 2, y: para.y + 60 }, button: 3)
    @automation.key("escape")
    check("Escape dismisses the copy menu without clearing the selected text", !get(:dialog) && get(:page_text).selected_text == copied)
    @automation.click({ x: para.x + para.w / 2, y: para.y + 60 }, button: 3)
    @automation.click({ x: 10, y: 100 })
    check("Clicking outside dismisses the copy menu", !get(:dialog))
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

  def page_number_input
    { "010" => 10, "٠١٠٤" => 104, "۰۰۸" => 8 }.each do |text, expected|
      click(get(:page_field))
      @automation.key("control_a")
      @automation.type(text)
      @automation.key("enter")
      @automation.wait_frames
      check("Page input #{text} navigates in decimal", get(:reader)[:number] == expected)
    end
    click(get(:page_field))
    @automation.key("control_a")
    @automation.type("0x10")
    @automation.key("enter")
    check("Non-decimal page input leaves the reader on its current page with feedback", get(:reader)[:number] == 8 && !get(:page_feedback).text.empty?)
    @app.turn_page(2)
    file = get(:reader).fetch(:file)
    get(:reader)[:file] = file.merge("pages_count" => 12_345)
    set(pdf_volume: nil)
    @app.turn_page(2)
    click(get(:page_field))
    @automation.key("control_a")
    @automation.type("1,234")
    @automation.key("enter")
    @automation.wait_frames
    check("Grouped page numbers navigate and keep English comma formatting", get(:reader)[:number] == 1234 && get(:page_field).text == "1,234")
    total = @automation.layout.find { |node| node[:kind] == "Para" && node[:text] == "من 12,345" }
    check("Grouped page totals fit on one line", total && total[:h] < get(:page_field).height)
    shot("reader-grouped-page-number")
    click(get(:page_field))
    @automation.key("control_a")
    @automation.type("12,34")
    @automation.key("enter")
    check("Malformed number grouping does not navigate", get(:reader)[:number] == 1234 && !get(:page_feedback).text.empty?)
    get(:reader)[:file] = file
    set(pdf_volume: nil)
    @app.turn_page(2)
  ensure
    get(:reader)[:file] = file if file
  end

  def scopes
    other_book = AlignmentVerification::BOOKS[1]
    other_author = other_book.fetch("author")
    @store.add_pages(other_book.fetch("id"), [{ "id" => 940_002, "number" => 2, "content" => @text }])
    other_category = AlignmentVerification::CATEGORIES.first
    category_book = @book.merge("id" => 940_010, "title" => "الجامع في علوم القرآن", "category" => other_category, "pages_count" => 1,
      "files" => [{ "id" => 940_010, "name" => "الكتاب", "pages_count" => 1, "urls" => {} }])
    @store.prepare_download(category_book)
    @store.add_pages(940_010, [{ "id" => 940_010, "number" => 1, "content" => @text }])
    @store.complete_download(category_book.fetch("id"))
    set(downloaded_ids: @store.downloaded_ids)
    @app.browse_scope(:author, @book.fetch("author"))
    settle
    author_scope = { author: @book.dig("author", "id") }
    label = get(:scope_label)
    click(action(:filters))
    check("The page author can be changed in filters", action([:filter, :author]).state.nil?)
    select_filter(:category, @book.dig("category", "name"))
    select_filter(:library, @book.dig("library", "name"))
    click(action("تطبيق"))
    settle
    both = author_scope.merge(category: @book.dig("category", "id"), library: @book.dig("library", "id"))
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
    click(action(:search_scope))
    click(action("كتبي المحمّلة"))
    settle
    click(action(:search_order))
    click(action("ترتيب المكتبة"))
    settle

    @app.open_filters
    select_filter(:author, other_author.fetch("name"))
    check("Changing the author is only a draft until Apply", get(:filters) == both && get(:scope_label) == label &&
      get(:dialog).dig(:filters, :author) == other_author.fetch("id"))
    @automation.key("escape")
    check("Cancel discards the author change", !get(:dialog) && get(:filters) == both && get(:scope_label) == label)
    @app.open_filters
    select_filter(:author, other_author.fetch("name"))
    click(action("تطبيق"))
    settle
    changed = both.merge(author: other_author.fetch("id"))
    check("Changing authors updates the heading and preserves other filters", get(:filters) == changed &&
      get(:scope_filters) == { author: other_author.fetch("id") } && heading?(other_author.fetch("name")))
    check("Changing authors preserves the query, text mode, downloaded scope, and sort", get(:query) == "العلم" &&
      get(:mode) == :content && get(:search_scope) == :downloaded && get(:search_order) == :library)
    hits = get(:result).data.fetch("pages")
    check("Changed-author results come from the selected author", !hits.empty? && hits.all? { |hit| hit.dig("book", "id") == other_book.fetch("id") })
    shot("changed-author-scope")
    back
    check("Back restores the previous author and filters", get(:filters) == both && heading?(label))
    forward
    check("Forward restores the new author and results", get(:filters) == changed && heading?(other_author.fetch("name")) && get(:result).data.fetch("pages") == hits)

    @app.open_filters
    select_filter(:author, "جميع المؤلفين")
    click(action("تطبيق"))
    settle
    check("Clearing the author returns to Books and keeps the query and other filters", get(:screen) == :browse &&
      get(:scope_filters).empty? && get(:scope_label).nil? && heading?("الكتب") && get(:filters) == both.except(:author) && get(:query) == "العلم")
    hits = get(:result).data.fetch("pages")
    check("Cleared-author results include both matching authors", hits.map { |hit| hit.dig("book", "author", "id") }.uniq.sort == [both[:author], changed[:author]].sort)
    shot("cleared-author-scope")

    @app.browse_scope(:category, @book.fetch("category"))
    settle
    click(get(:query_field))
    @automation.type("الجامع")
    @automation.key("enter")
    settle
    @app.open_filters
    check("The page category can be changed in filters", action([:filter, :category]).state.nil?)
    select_filter(:author, @book.dig("author", "name"))
    select_filter(:library, @book.dig("library", "name"))
    select_filter(:category, other_category.fetch("name"))
    click(action("تطبيق"))
    settle
    check("Changing category updates its heading while preserving author and library", heading?(other_category.fetch("name")) &&
      get(:scope_filters) == { category: other_category.fetch("id") } && get(:filters) == both.merge(category: other_category.fetch("id")))
    check("Changing category preserves title search and returns matching books", get(:query) == "الجامع" && get(:mode) == :books &&
      get(:result).data.fetch("books").map { |book| book.fetch("id") } == [category_book.fetch("id")])
    shot("changed-category-scope")
    @app.open_filters
    select_filter(:category, "الجميع")
    click(action("تطبيق"))
    settle
    check("Clearing category returns to Books with the other filters intact", get(:scope_filters).empty? && get(:scope_label).nil? &&
      heading?("الكتب") && get(:filters) == both.except(:category) && get(:query) == "الجامع")
    check("Cleared-category results include books from both categories", get(:result).data.fetch("books").map { |book| book.fetch("id") }.sort == [@book.fetch("id"), category_book.fetch("id")].sort)

    @app.browse_scope(:category, other_category)
    settle
    @app.open_filters
    click(action("مسح التصفية"))
    @automation.key("escape")
    check("Cancel also discards Clear filters", get(:filters) == { category: other_category.fetch("id") } && heading?(other_category.fetch("name")))
    @app.open_filters
    click(action("مسح التصفية"))
    click(action("تطبيق"))
    settle
    check("Clear filters removes the page scope and returns to Books", get(:filters).empty? && get(:scope_filters).empty? && get(:scope_label).nil? && heading?("الكتب"))

    @app.browse_scope(:library, @book.fetch("library"))
    settle
    @app.open_filters
    other_library = AlignmentVerification::LIBRARIES[1]
    select_filter(:library, other_library.fetch("name"))
    click(action("تطبيق"))
    settle
    check("Library pages use the same editable scope behavior", get(:filters) == { library: other_library.fetch("id") } &&
      get(:scope_filters) == get(:filters) && heading?(other_library.fetch("name")))
  end

  def select_filter(key, label)
    click(action([:filter, key]))
    settle
    click(action(label))
  end

  def heading?(label)
    @automation.layout.any? { |node| node[:kind] == "Para" && node[:text] == label && node[:y] < 120 }
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
    get(:pdf_images)[get(:reader).fetch(:number)] = image
    @app.draw_window
    check("Fit is disabled when the page is already fitted", get(:fit_button).state == "disabled")
    @app.define_singleton_method(:request_pdf_page) {}
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
    reader_copy_menu_at_edge
    @automation.resize(1160, 820)
    @app.tick
  ensure
    @app.singleton_class.remove_method(:request_pdf_page) if @app.singleton_methods.include?(:request_pdf_page)
  end

  def reader_copy_menu_at_edge
    @app.toggle_theme
    @automation.wait_frames
    pane = @automation.rect_of!(get(:text_surface).linkable_id)
    @automation.click({ x: pane.x + pane.w - 24, y: pane.y + 24 })
    @automation.key("command_a")
    @automation.click({ x: pane.x + pane.w - 24, y: pane.y + pane.h - 24 }, button: 3)
    panel = @automation.rect_of!(get(:dialog_panel).linkable_id)
    check("The dark reader copy menu stays inside the minimum-size window",
      get(:dialog)[:type] == :reader_copy && panel.x >= 16 && panel.y >= 16 &&
      panel.x + panel.w <= @app.width - 16 && panel.y + panel.h <= @app.height - 16)
    shot("reader-copy-menu-dark")
    @automation.key("enter")
    @automation.wait_frames
    check("Copy text works by keyboard in the right-hand split pane", !get(:dialog) && @app.clipboard == @text)
    @app.turn_page(1)
    @automation.wait_frames
    @automation.click({ x: pane.x + pane.w - 24, y: pane.y + 24 }, button: 3)
    check("Navigating pages cannot reopen a stale text selection", !get(:dialog) && get(:page_text).selected_text.empty?)
    @app.turn_page(2)
    @app.toggle_theme
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
