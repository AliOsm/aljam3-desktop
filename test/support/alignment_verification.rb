# frozen_string_literal: true

# Deterministic native checks shared by the source and packaged-app probes.
# All data lives in the probes' disposable library.
class AlignmentVerification
  CATEGORIES = ["علوم القرآن", "الحديث وعلومه", "العقيدة", "الفقه وأصوله", "السيرة النبوية", "اللغة العربية"].each_with_index.map do |name, index|
    { "id" => 900_000 + index, "name" => name, "books_count" => (index + 1) * 321 }
  end.freeze
  LIBRARIES = ["المكتبة الوقفية", "مكتبة المسجد النبوي", "المكتبة الشاملة الوقفية"].each_with_index.map do |name, index|
    { "id" => 900_000 + index, "name" => name, "books_count" => (index + 1) * 4321 }
  end.freeze
  BOOKS = [
    ["الجامع المسند الصحيح المختصر من أمور رسول الله صلى الله عليه وسلم وسننه وأيامه", "محمد بن إسماعيل البخاري"],
    ["رياض الصالحين", "أبو زكريا محيي الدين يحيى بن شرف النووي الدمشقي"],
    ["جامع بيان العلم وفضله", nil],
    ["الأذكار", "يحيى بن شرف النووي"]
  ].each_with_index.map do |(title, author), index|
    id = 910_000 + index
    { "id" => id, "title" => title, "pages_count" => 512, "files_count" => 1,
      "author" => author && { "id" => id, "name" => author },
      "category" => index == 2 ? nil : CATEGORIES.fetch(1), "library" => LIBRARIES.first,
      "files" => [{ "id" => id, "name" => "الكتاب", "pages_count" => 512, "urls" => {} }] }
  end.freeze

  def self.seed(store)
    store.save_preference("categories", CATEGORIES)
    store.save_preference("libraries", LIBRARIES)
    BOOKS.reverse_each do |book|
      store.prepare_download(book)
      store.add_pages(book.fetch("id"), [{ "id" => book.fetch("id"), "number" => 1, "content" => "نص تجريبي لفحص واجهة المكتبة." }])
      store.complete_download(book.fetch("id"))
      store.save_reading(book.fetch("id"), file_id: book.fetch("id"), number: 72)
    end
  end

  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks = []
  end

  def call
    store = @app.instance_variable_get(:@store)
    self.class.seed(store)
    set(categories: CATEGORIES, libraries: LIBRARIES, downloaded_ids: store.downloaded_ids)
    %i[light dark].each do |theme|
      set(theme:)
      @app.apply_theme
      [[1160, 820], [800, 700]].each do |width, height|
        @automation.resize(width, height)
        @label = "#{theme}-#{width}"
        home
        catalog
        categories
        authors
        dialog
        reader_options
      end
    end
    { passed: true, checks: @checks }
  end

  private

  def set(**values)
    values.each { |name, value| @app.instance_variable_set("@#{name}", value) }
  end

  def draw
    @app.draw_window
    @automation.wait_frames
    @layout = @automation.layout
  end

  def check(name, condition)
    raise "#{@label}: #{name}" unless condition

    @checks << "#{@label}: #{name}"
  end

  def near(a, b) = (a - b).abs < 0.6
  def right(node) = node.fetch(:x) + node.fetch(:w)
  def bottom(node) = node.fetch(:y) + node.fetch(:h)

  def node(kind, text)
    @layout.find { |entry| entry[:kind] == kind && entry[:text] == text } || raise("Missing #{kind}: #{text}")
  end

  def shot(name, scale: 1.25)
    path = File.join(@output, "#{name}-#{@label}.png")
    @automation.snapshot(path, scale:)
    path
  end

  def home
    @app.navigate(:home)
    draw
    search = node("Button", "بحث")
    heading = node("Para", "مكتبتك، حيث توقفت")
    explore = node("Para", "اكتشف المكتبة")
    @left, @right = search[:x], right(heading)
    cards = @layout.select { |entry| entry[:kind] == "Border" && entry[:y] < explore[:y] }
    check("home search and reading cards share outer edges", near(cards.map { |entry| entry[:x] }.min, @left) && near(cards.map { |entry| right(entry) }.max, @right))
    if @app.width > 1000
      check("reading columns share top and bottom", cards.size == 2 && near(cards[0][:y], cards[1][:y]) && near(bottom(cards[0]), bottom(cards[1])))
      check("section headings share a baseline", near(node("Para", "تابع القراءة")[:y], node("Para", "قرأت مؤخرًا")[:y]))
    end
    libraries = @layout.select { |entry| entry[:kind] == "Border" && entry[:y] > explore[:y] }.sort_by { |entry| entry[:x] }
    first_row = libraries.select { |entry| near(entry[:y], libraries.map { |item| item[:y] }.min) }
    check("library grid shares search boundaries", near(first_row.first[:x], @left) && near(right(first_row.last), @right))
    gaps = first_row.each_cons(2).map { |a, b| b[:x] - right(a) }
    check("library gutters are even", gaps.all? { |gap| gap.between?(16, 32) && near(gap, gaps.first) })
    check("library tiles have compact content", first_row.all? { |tile| tile[:h].between?(64, 96) })
    LIBRARIES.first(first_row.length).each do |library|
      title = node("Para", library.fetch("name"))
      count = node("Para", "#{library.fetch('books_count')} كتاب")
      tile = first_row.find { |entry| title[:x] >= entry[:x] && right(title) <= right(entry) + 1 }
      check("library title and count have balanced padding", title[:y] - tile[:y] >= 15 && bottom(tile) - bottom(count) >= 15)
    end
    status
    shot("home")
    focus(@app.instance_variable_get(:@query_field), "home-focus")
  end

  def catalog
    pagination = { "current_page" => 1, "total_pages" => 1, "count" => BOOKS.length }
    set(screen: :browse, mode: :books, query: "", result: Aljam3::Result.new({ "books" => BOOKS, "pagination" => pagination }, :downloaded, nil),
      source: :downloaded, busy: false, results: nil)
    draw
    check("Books has only one Authors navigation entry", @layout.count { |entry| entry[:kind] == "Button" && entry[:text] == "المؤلفون" } == 1)
    cards = @layout.select { |entry| entry[:kind] == "Border" }
    check("book grid shares search boundaries", near(cards.map { |entry| entry[:x] }.min, @left) && near(cards.map { |entry| right(entry) }.max, @right))
    buttons = @layout.select { |entry| entry[:kind] == "Button" && entry[:text] == "قراءة" }
    if @app.width > 1000
      check("book footers align with mixed title lengths and missing metadata", buttons.each_slice(2).all? { |a, b| near(a[:y], b[:y]) })
      check("authors align below wrapped titles", near(node("Para", BOOKS[0].dig("author", "name"))[:y], node("Para", BOOKS[1].dig("author", "name"))[:y]))
      check("long titles remain fully wrapped", node("Para", BOOKS[0].fetch("title"))[:h] > node("Para", BOOKS[1].fetch("title"))[:h])
    else
      check("compact cards stack without overlaps", cards.each_cons(2).all? { |a, b| bottom(a) + 15 < b[:y] })
    end
    status
    shot("books")
  end

  def categories
    @app.navigate(:categories)
    draw
    field = @layout.find { |entry| entry[:kind] == "EditLine" }
    rules = @layout.select { |entry| entry[:kind] == "Background" && near(entry[:h], 1) && entry[:y] > field[:y] && entry[:y] < @app.height - 40 }
    check("category search and rows share boundaries", near(field[:x], rules.map { |entry| entry[:x] }.min) && near(right(field), rules.map { |entry| right(entry) }.max))
    CATEGORIES.each do |category|
      label = node("Para", category.fetch("name"))
      below = rules.select { |rule| rule[:y] >= bottom(label) && near(right(rule), right(label) + 100) }.min_by { |rule| rule[:y] }
      # Rows reserve the count at the logical end; the name starts at the right edge.
      below ||= rules.select { |rule| rule[:y] >= bottom(label) && near(right(rule), right(label)) }.min_by { |rule| rule[:y] }
      check("category label clears its divider", below && below[:y] - bottom(label) >= 15)
      above = rules.select { |rule| rule[:y] < label[:y] && near(rule[:x], below[:x]) }.max_by { |rule| rule[:y] }
      check("category row has space after the previous divider", !above || label[:y] - bottom(above) >= 15)
    end
    status
    shot("categories")
    focus(field.fetch(:id), "category-focus")
  end

  def dialog
    @app.open_dialog(:choices, title: "اختر التصنيف", query: "", choices: [*CATEGORIES, { "name" => "التاريخ الإسلامي", "id" => 900_010 }].map { |item| item.values_at("name", "id") }, selection: ->(_) {})
    draw
    panel = @automation.rect_of!(@app.instance_variable_get(:@dialog_panel).linkable_id)
    check("dialog fits the viewport", panel.x >= 16 && panel.y >= 16 && panel.x + panel.w <= @app.width - 16 && panel.y + panel.h <= @app.height - 16)
    focus(@app.instance_variable_get(:@dialog_first), "dialog-focus")
    @app.close_dialog
  end

  def authors
    authors = BOOKS.first(2).each_with_index.map { |book, index| book.fetch("author").merge("books_count" => 13 + index) }
    pagination = { "current_page" => 1, "total_pages" => 2, "count" => 30 }
    set(screen: :authors, mode: :authors, query: "", results: nil, busy: false,
      result: Aljam3::Result.new({ "authors" => authors, "pagination" => pagination }, :downloaded, nil))
    draw
    cards = @layout.select { |entry| entry[:kind] == "Border" }
    authors.each do |author|
      count = node("Para", "#{author.fetch('books_count')} كتاب")
      card = cards.find { |entry| count[:x] >= entry[:x] && right(count) <= right(entry) && count[:y] > entry[:y] && bottom(count) < bottom(entry) }
      check("author count clears the card edge", card && right(card) - right(count) >= 15 && bottom(card) - bottom(count) >= 15)
    end
    following, previous = node("Button", "التالي"), node("Button", "السابق")
    check("pagination is centered in the content", near((following[:x] + right(previous)) / 2, (@left + @right) / 2))
    check("Next is at the logical end in RTL", right(following) < previous[:x])
    shot("authors")
  end

  def reader_options
    book = BOOKS.first
    reader = { book:, files: book.fetch("files"), file: book.fetch("files").first, number: 1,
      zoom: 1.0, mode: :split, text_size: 21, tashkeel: true, split_ratio: 0.5, query: "",
      page: { "content" => "آدابُ الْعِلْمِ وأَهْلِهِ" } }
    set(screen: :reader, reader:, bookmarks: [], results: nil)
    draw
    check("single file readers omit the redundant volume label", !@layout.any? { |entry| entry[:kind] == "Para" && entry[:text] == "الكتاب" })
    @app.open_dialog(:reader_options)
    draw
    panel = @automation.rect_of!(@app.instance_variable_get(:@dialog_panel).linkable_id)
    hint = node("Para", "تُحفظ اختياراتك تلقائيًا.")
    check("reading options have no empty footer", (panel.y + panel.h - bottom(hint)).between?(16, 28))
    presets = %w[صورة\ أوسع متساويان نص\ أوسع].map { |label| node("Button", label) }.sort_by { |entry| entry[:x] }
    check("split presets have separate hit areas", presets.each_cons(2).all? { |a, b| (b[:x] - right(a)).between?(7, 9) })
    shot("reading-options")
    %w[تكبير\ النص تصغير\ النص].each do |label|
      button = @app.instance_variable_get(:@action_views).fetch(label)
      icon_center(button, label)
    end
    larger = @app.instance_variable_get(:@text_larger)
    larger.focus
    @automation.key("space")
    @automation.key("space")
    check("font size adjusts repeatedly without losing focus", reader[:text_size] == 25 && @automation.focused == larger.linkable_id)
    toggle = @app.instance_variable_get(:@tashkeel_switch)
    @automation.click({ id: toggle.linkable_id })
    check("tashkeel switches off without moving focus", !reader[:tashkeel] && @automation.focused == toggle.linkable_id)
    @automation.key("tab")
    @automation.key("shift_tab")
    @automation.key("space")
    check("tashkeel toggle supports pointer and keyboard", reader[:tashkeel] && @automation.focused == toggle.linkable_id)
    check("tashkeel choice is saved", @app.instance_variable_get(:@store).preference("reader").fetch("tashkeel"))
    @app.close_dialog
    @app.open_dialog(:export)
    draw
    panel = @automation.rect_of!(@app.instance_variable_get(:@dialog_panel).linkable_id)
    file = node("Para", "الكتاب")
    check("single-file export is compact", panel.h < 260 && (panel.y + panel.h - bottom(file)).between?(16, 48))
    shot("export")
    @app.close_dialog
    reader[:files] = Array.new(12) { |index| reader.fetch(:file).merge("id" => index + 1, "name" => "المجلد #{index + 1}") }
    @app.open_dialog(:export)
    draw
    panel = @automation.rect_of!(@app.instance_variable_get(:@dialog_panel).linkable_id)
    files = @app.instance_variable_get(:@dialog_results)
    check("many-file export stays bounded and scrolls", panel.y >= 16 && panel.y + panel.h <= @app.height - 16 && files.scroll_max.positive?)
    files.scroll_top = files.scroll_max
    @automation.wait_frames
    @layout = @automation.layout
    last = node("Para", "المجلد 12")
    check("last export file remains reachable", bottom(last) <= panel.y + panel.h - 20 && last[:y] >= panel.y + 76)
    shot("export-volumes")
    @app.close_dialog
    reader[:files] = book.fetch("files")
    reader[:mode] = :text
    @app.open_dialog(:reader_options)
    draw
    check("text-only reader hides split controls", !@layout.any? { |entry| entry[:kind] == "Button" && entry[:text] == "نص أوسع" })
    @app.close_dialog
    @app.navigate(:home)
  end

  def icon_center(button, label)
    bounds = @automation.rect_of!(button.linkable_id)
    picture = ChunkyPNG::Image.from_file(shot("icon-centering", scale: 2))
    ink = ChunkyPNG::Color.from_hex(@app.ink)
    points = []
    (bounds.y * 2).ceil.upto(((bounds.y + bounds.h) * 2).floor - 1) do |y|
      (bounds.x * 2).ceil.upto(((bounds.x + bounds.w) * 2).floor - 1) do |x|
        points << [x, y] if picture[x, y] == ink
      end
    end
    check("#{label} glyph is centered", !points.empty? &&
      (points.sum(&:first).fdiv(points.size) - (bounds.x + bounds.w / 2) * 2).abs <= 2 &&
      (points.sum(&:last).fdiv(points.size) - (bounds.y + bounds.h / 2) * 2).abs <= 2)
  end

  def status
    bar = @automation.rect_of!(@app.instance_variable_get(:@connection_bar).linkable_id)
    check("status bar stays at the bottom", near(bar.y + bar.h, @app.height) && bar.h <= 36)
    results = @automation.rect_of!(@app.instance_variable_get(:@results).linkable_id)
    check("content clears the status bar", results.y + results.h + 15 <= bar.y)
  end

  def focus(field, name)
    id = field.respond_to?(:linkable_id) ? field.linkable_id : field
    @automation.click({ id: })
    @automation.wait_frames
    bounds = @automation.rect_of!(id)
    [1, 1.25, 2].each do |scale|
      path = File.join(@output, "#{name}-#{@label}-#{scale}x.png")
      @automation.snapshot(path, scale:)
      picture = ChunkyPNG::Image.from_file(path)
      color = ChunkyPNG::Color.from_hex(@app.primary)
      edges = [[bounds.x + bounds.w / 2, bounds.y, 0, 1], [bounds.x, bounds.y + bounds.h / 2, 1, 0],
        [bounds.x + bounds.w - 1, bounds.y + bounds.h / 2, -1, 0], [bounds.x + bounds.w / 2, bounds.y + bounds.h - 1, 0, -1]]
      check("#{name} has four complete focus edges at #{scale}x", edges.all? do |x, y, dx, dy|
        (0...(5 * scale).ceil).any? do |offset|
          ink = picture[(x * scale + offset * dx).floor, (y * scale + offset * dy).floor]
          [ChunkyPNG::Color.r(ink) - ChunkyPNG::Color.r(color), ChunkyPNG::Color.g(ink) - ChunkyPNG::Color.g(color),
            ChunkyPNG::Color.b(ink) - ChunkyPNG::Color.b(color)].all? { |delta| delta.abs <= 8 }
        end
      end)
    end
  end
end
