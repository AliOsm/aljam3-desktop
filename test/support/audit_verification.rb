# frozen_string_literal: true

require "timeout"
require_relative "alignment_verification"
require_relative "range_pdf"

# Exercise complete user journeys, including keyboard submission and late work.
class AuditVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks, @failures = [], []
    @store = get(:store)
  end

  def call
    MotionPreference.set(@app, reduced: true)
    get(:ticker).remove
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    wait { ready }
    seed
    %i[navigation catalog_search content_search category_search filter_search reader_controls reader_search online_recovery reconnect_search grouped_downloads cache_navigation update_actions].each do |scenario|
      begin
        @app.navigate(:home)
        settle
        send(scenario)
      rescue StandardError => error
        @failures << "#{scenario}: #{error.message}"
        shot("failed-#{scenario}")
      end
    end
    report = { passed: @failures.empty?, checks: @checks, failures: @failures }
    File.write(File.join(@output, "audit.json"), JSON.pretty_generate(report))
    raise @failures.join("\n") unless @failures.empty?

    report
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |key, value| @app.instance_variable_set("@#{key}", value) }
  def action(key) = get(:action_views).fetch(key)
  def click(control) = @automation.click({ id: control.linkable_id })
  def activate(control, key = "enter")
    control.focus
    @automation.key(key)
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
  def settle
    wait do
      !get(:busy) && !get(:dialog)&.dig(:busy) &&
        !(get(:dialog)&.dig(:type) == :book_search && get(:book_search)[:busy]) &&
        !(get(:screen) == :reader && get(:reader)[:loading_text])
    end
  end
  def type(field, query)
    click(field)
    @automation.key("control_a")
    @automation.type(query)
  end
  def submit(field, query, method = :enter)
    type(field, query)
    method == :enter ? @automation.key("enter") : click(action("بحث"))
    settle
  end

  def seed
    categories = AlignmentVerification::ALL_CATEGORIES
    @books = (1..30).map do |number|
      id = 980_000 + number
      files = (1..(number == 1 ? 2 : 1)).map do |part|
        { "id" => id * 10 + part, "name" => "المجلد #{part}", "pages_count" => 6, "urls" => {} }
      end
      { "id" => id, "title" => "كتاب الاختبار #{number}", "author" => { "id" => id, "name" => "مؤلف الاختبار #{number}", "books_count" => 1 },
        "category" => categories[number % 2], "library" => AlignmentVerification::LIBRARIES.first,
        "files" => files, "files_count" => files.length, "pages_count" => files.length * 6 }
    end
    @books.each do |book|
      @store.prepare_download(book)
      book.fetch("files").each do |file|
        @store.add_pages(file.fetch("id"), (1..6).map { |number| { "id" => file.fetch("id") * 10 + number, "number" => number,
          "content" => "العِلْم نور. العِلْم نافع. نص اختبار الصفحة #{number}." } })
      end
      @store.complete_download(book.fetch("id"), bytes: 100)
    end
    @book = @books.first
    @book.fetch("files").each do |file|
      path = get(:downloader).pdf_path(@book.fetch("id"), file.fetch("id"))
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, RangePDF.document(pages: 6))
    end
    @store.save_preference("categories", categories)
    @store.save_preference("libraries", AlignmentVerification::LIBRARIES)
    @store.save_preference("reader", { "mode" => "text" })
    set(categories:, libraries: AlignmentVerification::LIBRARIES, downloaded_ids: @store.downloaded_ids)
  end

  def navigation
    %i[home categories authors browse saved downloads].each_with_index do |screen, index|
      activate(get(:navigation_buttons).fetch(screen), index.even? ? "enter" : "space")
      settle
      check("Header keyboard activation opens #{screen}", get(:screen) == screen && !@app.dialog_active?)
    end
    theme = get(:theme)
    2.times { click(action(get(:theme) == :dark ? "الوضع الفاتح" : "الوضع الداكن")) }
    check("Theme controls change and persist the selected appearance", get(:theme) == theme && @store.preference("theme") == theme.to_s)
  end

  def catalog_search
    %i[home browse authors saved].each do |screen|
      click(get(:navigation_buttons).fetch(screen))
      settle
      results = %i[enter button].map do |method|
        request = get(:request_number)
        submit(get(:query_field), "الاختبار", method)
        check("#{screen} search via #{method} completes exactly one request", get(:request_number) == request + 1 && !get(:error))
        data = get(:result).data
        check("#{screen} search via #{method} immediately displays matching results", data.fetch("pagination").fetch("count") == 30 &&
          @automation.layout.none? { |node| node[:text] == "جارٍ البحث…" })
        data.fetch(@app.result_key).map { |item| item.fetch("id") }
      end
      check("#{screen} Enter and Search show the same results", results.first == results.last)
      get(:results).scroll_top = get(:results).scroll_max
      @automation.wait_frames
      click(action("التالي"))
      settle
      check("#{screen} Next opens page two at the top", get(:result).data.dig("pagination", "current_page") == 2 && get(:results).scroll_top.zero?)
      submit(get(:query_field), "عنوان غير موجود")
      check("#{screen} a new Enter search resets pagination and displays no results", get(:result).data.dig("pagination", "count").zero? &&
        get(:result).data.dig("pagination", "current_page") == 1 && @automation.layout.any? { |node| node[:text] == "لا توجد نتائج" })
    end
  end

  def category_search
    click(get(:navigation_buttons).fetch(:categories))
    @automation.key("control_f")
    field = @automation.layout.find { |node| node[:kind] == "EditLine" }
    check("Find focuses the category search field", field && @automation.focused == field[:id])
    @automation.type("غير موجود")
    check("Category live search displays the empty state", @automation.layout.any? { |node| node[:text] == "لا توجد تصنيفات مطابقة" })
    @automation.key("control_a")
    @automation.key("backspace")
    check("Clearing category search restores the category list", @automation.layout.any? { |node| node[:text] == get(:categories).first.fetch("name") })
  end

  def content_search
    %i[home browse saved].each do |screen|
      click(get(:navigation_buttons).fetch(screen))
      settle
      click(action(:search_mode))
      click(action("نصوص الكتب"))
      settle
      results = %i[enter button].map do |method|
        submit(get(:query_field), "العلم", method)
        result = get(:result).data
        check("#{screen} text search via #{method} returns searchable offline pages", result.fetch("pages").length == 12 &&
          result.dig("pagination", "count") == 186 && !get(:error))
        result.fetch("pages").map { |hit| hit.fetch("id") }
      end
      check("#{screen} text search agrees for Enter and the button", results.first == results.last)
    end
  end

  def filter_search
    click(action(:filters))
    click(action([:filter, :category]))
    type(get(:dialog_first), "غير موجود")
    check("Nested category filter searches without losing focus", @automation.focused == get(:dialog_first).linkable_id &&
      @automation.layout.any? { |node| node[:text] == "لا توجد خيارات مطابقة." })
    @automation.key("escape")
    check("Escape returns from category selection to its filter draft", get(:dialog)[:type] == :filters && get(:filters).empty?)
    click(action([:filter, :author]))
    settle
    get(:dialog_results).scroll_top = get(:dialog_results).scroll_max
    @automation.wait_frames
    click(action("التالي"))
    settle
    check("Author picker Next displays the next page from the top", get(:dialog).fetch(:result).data.dig("pagination", "current_page") == 2 && get(:dialog_results).scroll_top.zero?)
    submit(get(:dialog_first), "مؤلف الاختبار")
    check("Author picker Enter resets the result scroll and page", get(:dialog).fetch(:result).data.dig("pagination", "current_page") == 1 && get(:dialog_results).scroll_top.zero?)
  end

  def reader_controls
    @app.open_book(@book)
    settle
    click(get(:next_page_button))
    check("Next-page button advances the reader", get(:reader)[:number] == 2)
    @automation.key("control_j")
    check("Jump shortcut focuses the page field", @automation.focused == get(:page_field).linkable_id)
    type(get(:page_field), "4")
    @automation.key("left")
    check("Arrow editing in the page field does not change pages", get(:reader)[:number] == 2)
    @automation.key("enter")
    check("Enter navigates to the edited page number", get(:reader)[:number] == 4)
    click(get(:bookmark_button))
    check("Bookmark button stores the current page", @app.bookmarked?)
    @automation.key("control_d")
    check("Bookmark shortcut toggles the same bookmark", !@app.bookmarked?)
    click(action("خيارات القراءة"))
    8.times { click(get(:text_larger)) unless get(:text_larger).state == "disabled" }
    check("Text size stops at its upper limit", get(:reader)[:text_size] == 35 && get(:text_larger).state == "disabled")
    10.times { click(get(:text_smaller)) unless get(:text_smaller).state == "disabled" }
    check("Text size stops at its lower limit and persists", get(:reader)[:text_size] == 17 && @store.preference("reader")["text_size"] == 17)
    activate(get(:tashkeel_switch), "space")
    check("Keyboard toggling of diacritics changes the displayed text", !get(:reader)[:tashkeel] && !@app.page_text.include?("ِ"))
    @automation.key("escape")
    click(action("ملفات الكتاب"))
    click(action("المجلد 2 · 6 صفحة"))
    settle
    check("Volume selection opens the chosen volume at page one", get(:reader).dig(:file, "id") == @book.fetch("files").last.fetch("id") && get(:reader)[:number] == 1)
    click(get(:next_page_button))
    click(get(:bookmark_button))
    click(action("أدوات الكتاب"))
    activate(action("مشاركة الصفحة"))
    click(action("نسخ الرابط"))
    check("Share copies the current volume and page", @app.clipboard == "https://aljam3.com/ar/#{@book.fetch('id')}/#{@book.fetch('files').last.fetch('id')}/2")
    @automation.key("escape")
    click(get(:navigation_buttons).fetch(:home))
    click(action("متابعة القراءة"))
    settle
    check("Continue reading restores the volume, page, and bookmark", get(:reader).dig(:file, "id") == @book.fetch("files").last.fetch("id") && get(:reader)[:number] == 2 && @app.bookmarked?)
    click(action("أدوات الكتاب"))
    click(action("الفواصل المحفوظة"))
    activate(action("فتح الصفحة"))
    check("A saved bookmark opens without leaving a blocking dialog", get(:reader)[:number] == 2 && !@app.dialog_active?)
  end

  def reader_search
    @app.open_book(@book)
    settle
    @automation.key("command_f")
    results = %i[enter button].map do |method|
      submit(get(:book_query_field), "العلم", method)
      search = get(:book_search)
      check("Book search via #{method} displays its result immediately", !search[:error] && !search[:busy] && search.fetch(:result).data.fetch("pages").length == 12)
      search.fetch(:result).data.fetch("pages").map { |hit| hit.fetch("id") }
    end
    check("Book-search Enter and Search agree", results.first == results.last)
    button = @automation.layout.find { |node| node[:kind] == "Button" && node[:text] == "عرض الصفحة" }
    @automation.click({ id: button.fetch(:id) })
    settle
    check("A book-search hit opens with highlighted matches", !@app.dialog_active? && get(:reader)[:query] == "العلم" && get(:match_label).text.include?("2"))
    @automation.key("f3")
    check("F3 advances the active match", get(:reader)[:match_index] == 1)
    @automation.key("shift_f3")
    check("Shift F3 returns to the previous match", get(:reader)[:match_index].zero?)
    @automation.key("escape")
    check("Escape clears reader search highlighting", get(:reader)[:query].empty? && !get(:match_label))
  end

  def online_recovery
    api = get(:api)
    api.define_singleton_method(:connection) { :online }
    set(connection: :online)
    @store.save_preference("reader", { "mode" => "text" })
    book = @book.merge("id" => 995_001, "title" => "كتاب القراءة المباشرة")
    api.define_singleton_method(:book) { |_id| book }
    api.define_singleton_method(:page) { |*_args| raise Aljam3::ConnectionError, "audit text unavailable" }
    @app.open_book(book)
    wait { get(:screen) == :reader && !get(:reader)[:loading_text] }
    check("An online text failure exposes a retry without blocking navigation", get(:reader)[:text_error] && action("إعادة تحميل النص"))
    api.define_singleton_method(:page) { |_file, number| { "id" => 995_100 + number, "number" => number, "content" => "استعاد النص اتصاله" } }
    click(action("إعادة تحميل النص"))
    settle
    check("The online text retry restores reading and copying", @app.page_text == "استعاد النص اتصاله" && get(:copy_button).state.nil?)
    @app.navigate(:browse)
    settle
    book = book.merge("files" => [])
    @app.open_book(book)
    wait { get(:screen) != :opening }
    check("A book with unavailable files reports an error without leaving the app stuck", get(:screen) == :browse &&
      get(:notifications).find([:open_book_failed, book.fetch("id")]))
    book = book.merge("files" => @book.fetch("files"))
    click(get(:notice_action))
    wait { get(:screen) == :reader && !get(:reader)[:loading_text] }
    check("The failed-book notification can retry and clear its error", !get(:notifications).find([:open_book_failed, book.fetch("id")]))
    @app.navigate(:home)
    api.define_singleton_method(:book) { |_id| raise Aljam3::ResponseError.new(503) }
    @app.open_book(book)
    wait { get(:screen) != :opening }
    check("An opening failure from Home remains visible and actionable", get(:screen) == :home && get(:notifications).find([:open_book_failed, book.fetch("id")]))
  ensure
    %i[connection book page].each { |name| api.singleton_class.remove_method(name) if api&.singleton_methods&.include?(name) }
  end

  def reconnect_search
    get(:notifications).dismiss while get(:notifications).current
    submit(get(:query_field), "الاختبار")
    check("The reconnect journey begins with offline Home search results", get(:source) == :offline)
    api = get(:api)
    state = :offline
    categories, libraries = get(:categories), get(:libraries)
    online = @book.merge("id" => 995_002, "title" => "كتاب الاختبار من الشبكة")
    api.define_singleton_method(:connection) { state }
    api.define_singleton_method(:categories) { state = :online; categories }
    api.define_singleton_method(:libraries) { libraries }
    api.define_singleton_method(:books) do |**_options|
      { "books" => [online], "pagination" => { "count" => 1, "current_page" => 1, "total_pages" => 1, "next_page" => nil } }
    end
    click(get(:reconnect_button))
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    wait { ready && !get(:busy) }
    check("Reconnect refreshes an existing Home search with online results", get(:source) == :online && get(:result).data.fetch("books").map { |item| item.fetch("id") } == [995_002])

    state = :offline
    @app.tick
    entered, release = Queue.new, Queue.new
    api.define_singleton_method(:categories) { entered << true; release.pop; state = :online; categories }
    click(get(:reconnect_button))
    wait { !entered.empty? }
    field = get(:query_field)
    type(field, "مسودة جديدة")
    release << true
    ready = false
    get(:network_worker).submit(-> { nil }) { ready = true }
    wait { ready }
    check("Reconnection preserves an in-progress query and its keyboard focus", get(:query_field).equal?(field) && field.text == "مسودة جديدة" && @automation.focused == field.linkable_id)
    @automation.key("enter")
    settle
    check("The preserved query can be submitted normally after reconnecting", get(:query) == "مسودة جديدة" && !get(:busy))
  ensure
    release&.push(true)
    %i[connection categories libraries books].each { |name| api.singleton_class.remove_method(name) if api&.singleton_methods&.include?(name) }
  end

  def grouped_downloads
    category = { "id" => 990_001, "name" => "تصنيف التدقيق" }
    books = (1..3).map { |n| @book.merge("id" => 990_010 + n, "category" => category, "title" => "تنزيل التدقيق #{n}") }
    @store.cache_books(books)
    get(:download_queue).enqueue_category(category, books.map { |book| book.fetch("id") })
    get(:download_queue).pause_category(category.fetch("id"))
    @store.complete_download(books.first.fetch("id"), bytes: 100)
    @app.refresh_download_state
    click(get(:navigation_buttons).fetch(:downloads))
    click(action("المكتملة"))
    check("Completed downloads include finished books inside unfinished categories", get(:category_progress_views).key?(category.fetch("id")))
    click(action([:category_details, category.fetch("id")]))
    check("Completed category details contain only completed books", get(:category_book_labels).keys == [books.first.fetch("id")])
    click(action("غير المكتملة"))
    check("Incomplete category details contain only unfinished books", get(:category_book_labels).keys.sort == books.drop(1).map { |book| book.fetch("id") })
  end

  def cache_navigation
    @app.open_book(@book)
    click(action("النص والصورة"))
    wait { get(:reader)[:image] && !get(:pdf_pending) }
    click(get(:navigation_buttons).fetch(:downloads))
    click(action("مسح الصور المؤقتة"))
    @app.open_book(@book)
    wait { !get(:clearing_cache) && get(:reader)[:image] && !get(:pdf_pending) }
    check("Opening a PDF while cache clearing finishes regenerates its image", get(:pdf_images).key?(get(:reader)[:number]) && get(:page_image).url == get(:reader)[:image].path)
  end

  def update_actions
    updater = get(:updater)
    checks, downloads = 0, 0
    updater.define_singleton_method(:supported?) { true }
    updater.define_singleton_method(:check) { checks += 1; nil }
    @store.save_preference("update_checked_at", Time.now.to_i)
    set(update_state: :idle)
    click(action(:settings))
    activate(action("التحقق من التحديثات"))
    wait { get(:update_state) == :current }
    check("Keyboard update check reaches the current-version state", checks == 1)
    updater.define_singleton_method(:check) { checks += 1; raise Aljam3::ConnectionError, "audit offline" }
    click(action("التحقق من التحديثات"))
    wait { get(:update_state) == :error }
    check("Failed update checks return an actionable retry", action("التحقق من التحديثات").state.nil?)
    updater.define_singleton_method(:check) { checks += 1; { "version" => "9.0.0" } }
    updater.define_singleton_method(:download) { |_package, &progress| downloads += 1; progress.call(1); "fixture" }
    activate(action("التحقق من التحديثات"))
    @automation.key("escape")
    wait { get(:update_state) == :ready }
    check("Update retry finishes in the background after closing its dialog", checks == 3 && downloads == 1 && get(:notifications).find(:update_ready))
    set(file_operations: { audit: { status: :saving } })
    click(action(:settings))
    click(action("إعادة التشغيل والتحديث"))
    check("Restart for update waits for an active export", get(:update_state) == :ready && get(:update_wait_for_export))
  ensure
    %i[supported? check download].each { |name| updater.singleton_class.remove_method(name) if updater&.singleton_methods&.include?(name) }
    set(file_operations: {})
  end
end
