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
        dialog
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
    status
    shot("home")
    focus(@app.instance_variable_get(:@query_field), "home-focus")
  end

  def catalog
    pagination = { "current_page" => 1, "total_pages" => 1, "count" => BOOKS.length }
    set(screen: :browse, mode: :books, query: "", result: Aljam3::Result.new({ "books" => BOOKS, "pagination" => pagination }, :downloaded, nil),
      source: :downloaded, busy: false, results: nil)
    draw
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
