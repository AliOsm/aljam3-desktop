# frozen_string_literal: true

require_relative "motion_preference"

require_relative "alignment_verification"

class MotionVerification
  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @checks = []
  end

  def call
    get(:ticker).remove
    get(:preference_ticker).remove
    @app.tick
    get(:motion).cancel
    Shoes::DisplayService.display_service.clock.freeze!
    MotionPreference.set(@app, reduced: false)
    AlignmentVerification.seed(get(:store))
    set(categories: AlignmentVerification::CATEGORIES, libraries: AlignmentVerification::LIBRARIES, downloaded_ids: get(:store).downloaded_ids)
    reader
    overlays
    navigation
    categories
    nested_filters
    controls
    notifications
    preferences
    { passed: true, checks: @checks }
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |key, value| @app.instance_variable_set("@#{key}", value) }
  def advance(seconds) = @automation.advance(seconds)
  def visual(view, property) = @automation.properties(view.linkable_id).fetch(property)
  def click(control) = @automation.click({ id: control.linkable_id })

  def check(name, condition)
    raise name unless condition

    @checks << name
  end

  def shot(name) = @automation.snapshot(File.join(@output, "#{name}.png"), scale: 1.5)

  def reader
    book = AlignmentVerification::BOOKS.first
    set(screen: :reader, results: nil, bookmarks: [], reader: {
      book:, files: book.fetch("files"), file: book.fetch("files").first, number: 1,
      zoom: 1.0, mode: :split, text_size: 21, tashkeel: true, split_ratio: 0.5, query: "",
      page: { "content" => "آدابُ الْعِلْمِ وأَهْلِهِ\n" * 100 }
    })
    @app.draw_window
    @automation.wait_frames
    get(:text_surface).scroll_top = 180
    @automation.wait_frames
  end

  def overlays
    text, pdf = get(:text_surface), get(:pdf_surface)
    trigger = get(:action_views).fetch("خيارات القراءة")
    click(trigger)
    panel = get(:dialog_panel)
    check("overlay opening keeps both reader panes and scroll position", get(:text_surface).equal?(text) &&
      get(:pdf_surface).equal?(pdf) && text.scroll_top == 180)
    check("background is inert from the first frame", get(:content_layer).style[:inert])
    check("entrance starts transparent", visual(panel, :opacity).zero?)
    shot("popup-start")
    advance(0.05)
    check("popup fades and moves toward its anchor", visual(panel, :opacity).between?(0.1, 0.99) &&
      visual(panel, :displace_top).abs.between?(0.1, 5))
    shot("popup-midway")
    @automation.key("escape")
    opacity = visual(panel, :opacity)
    check("Escape reverses the in-progress entrance", !get(:dialog) && get(:closing_dialog) && !opacity.zero?)
    @automation.key("escape")
    advance(0.04)
    check("exit continues smoothly from the interrupted value", visual(panel, :opacity) < opacity)
    advance(0.12)
    check("close restores trigger focus and releases background input", !@app.dialog_active? &&
      !get(:content_layer).style[:inert] && @automation.focused == trigger.linkable_id)
    check("settled overlays remove the animation timer", !get(:motion).active?)

    click(trigger)
    advance(0.25)
    shot("popup-settled")
    ids = @automation.a11y.to_s
    check("background content is excluded from the accessibility tree", !ids.include?("الصفحة التالية"))
    12.times do
      @automation.key("tab")
      focused = @automation.focused
      background = get(:base_action_views).values.any? { |control| control.linkable_id == focused }
      check("Tab remains within the dialog #{_1 + 1}", !background)
    end
    @app.close_dialog
    @app.open_dialog(:share)
    advance(0.25)
    check("reopening during exit cancels stale cleanup", get(:dialog)&.dig(:type) == :share && !get(:dialog_layer).style[:hidden])
    shot("dialog-settled")
    @app.close_dialog
    advance(0.15)
    check("reader still has its original scroll position", text.scroll_top == 180 && get(:text_surface).equal?(text))
    @app.open_dialog(:share)
    advance(0.04)
    @automation.resize(800, 700)
    @app.tick
    advance(0.25)
    rect = @automation.rect_of!(get(:dialog_panel).linkable_id)
    check("resizing during entrance keeps the panel inside the window", rect.x >= 16 && rect.x + rect.w <= 784)
    @app.navigate(:home)
    advance(0.3)
    check("navigation cancels obsolete overlay jobs", !@app.dialog_active? && !get(:motion).active?)
  end

  def controls
    reader
    @app.open_dialog(:reader_options)
    advance(0.25)
    toggle = get(:tashkeel_switch)
    click(toggle)
    check("switch semantics and text change immediately", !get(:reader)[:tashkeel] && !toggle.checked?)
    advance(0.04)
    midway = visual(toggle, :switch_position)
    check("switch thumb has intermediate positions", midway.between?(0.1, 0.9))
    click(toggle)
    check("rapid switch reversal has no visual jump", visual(toggle, :switch_position) == midway)
    advance(0.15)
    check("switch ends at the latest requested value", visual(toggle, :switch_position) == 1.0)
    @app.close_dialog
    advance(0.15)
    control = get(:copy_button)
    @automation.hover(control.linkable_id)
    advance(0.04)
    check("button hover interpolates its color", visual(control, :hover_amount).between?(0.1, 0.99))
    @automation.leave(control.linkable_id)
    advance(0.15)
    check("button leave settles and stops ticking", visual(control, :hover_amount).zero? && !get(:motion).active?)
    bar = get(:activity_progress)
    @app.smooth_progress(bar, 0.7)
    advance(0.05)
    check("progress advances toward actual progress without overshooting", visual(bar, :fraction).positive? && visual(bar, :fraction) < 0.7)
    @app.smooth_progress(bar, 0.9)
    advance(0.20)
    check("progress settles at the latest reported value", visual(bar, :fraction) == 0.9 && !get(:motion).active?)
  end

  def navigation
    @app.navigate(:home)
    advance(0.3)
    chrome, status = get(:navigation_buttons).dup, get(:connection_bar)
    previous = get(:page_view)
    click(chrome.fetch(:browse))
    current = get(:page_view)
    check("navigation keeps the header and status bar alive", get(:navigation_buttons) == chrome && get(:connection_bar).equal?(status))
    check("cached books appear immediately in the arriving page", get(:result)&.data&.fetch("books")&.any?)
    check("outgoing pages stop receiving input immediately", previous.style[:inert] && !current.style[:inert])
    check("peer navigation starts a crossfade without sliding", visual(current, :opacity).zero? && visual(current, :displace_left).zero?)
    advance(0.06)
    opacity = visual(current, :opacity)
    check("the arriving page blends over a stable outgoing page", opacity.between?(0.1, 0.99) && visual(previous, :opacity) == 1.0)
    check("navigation retains keyboard focus on the header control", @automation.focused == chrome.fetch(:browse).linkable_id)
    check("outgoing home is absent from the accessibility tree", !@automation.a11y.to_s.include?("مكتبتك، حيث توقفت"))
    shot("navigation-midway")
    @app.refresh_window
    check("background refresh keeps the same page and animation position", get(:page_view).equal?(current) && visual(current, :opacity) == opacity)
    advance(0.15)
    check("navigation removes outgoing content and stops animating", previous.destroyed && get(:page_transition).views == [current] && !get(:motion).active?)
    @app.navigate(:browse)
    check("reselecting the current section does not replay navigation", get(:page_view).equal?(current) &&
      get(:page_transition).views == [current] && visual(current, :opacity) == 1.0)

    %i[categories authors downloads home].each do |screen|
      @app.navigate(screen)
      advance(0.025)
    end
    check("rapid navigation immediately shows the latest destination", get(:screen) == :home)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    @app.refresh_window
    check("typing during navigation survives a background refresh", get(:query_field).equal?(field) && field.text == "العلم" && @automation.focused == field.linkable_id)
    advance(0.2)
    check("interrupted navigation leaves one page and no queued animation", get(:page_transition).views.size == 1 && !get(:motion).active?)

    @app.navigate(:home)
    advance(0.2)
    get(:results).scroll_top = 80
    @automation.wait_frames
    scroll = get(:results).scroll_top
    get(:store).save_preference("reader", { "mode" => "text" })
    @app.open_book(AlignmentVerification::BOOKS.first)
    reader_page = get(:page_view)
    check("opening a book crossfades without moving the reader", visual(reader_page, :opacity).zero? && visual(reader_page, :displace_left).zero?)
    advance(0.05)
    opacity = visual(reader_page, :opacity)
    @app.turn_page(1)
    check("page turns update the reader without replaying its entrance", get(:page_view).equal?(reader_page) && visual(reader_page, :opacity) == opacity)
    advance(0.2)
    @app.close_reader
    check("returning from a book crossfades and restores scroll", visual(get(:page_view), :opacity).zero? && get(:results).scroll_top == scroll)
    advance(0.05)
    MotionPreference.set(@app, reduced: true)
    check("reducing motion mid-navigation settles and cleans outgoing pages", get(:page_transition).views.size == 1 && visual(get(:page_view), :opacity) == 1.0 && !get(:motion).active?)
    @app.navigate(:categories)
    check("reduced-motion navigation is immediate", visual(get(:page_view), :opacity) == 1.0 && get(:page_transition).views.size == 1 && !get(:motion).active?)
    MotionPreference.set(@app, reduced: false)
    @app.navigate(:home)
    advance(0.04)
    @automation.resize(1160, 820)
    @app.tick
    advance(0.2)
    check("resize during navigation leaves a single settled page", get(:page_transition).views.size == 1 && visual(get(:page_view), :opacity) == 1.0)
  end

  def categories
    all = AlignmentVerification::ALL_CATEGORIES
    set(categories: all)
    %i[home browse authors downloads].each do |from|
      @app.navigate(from)
      advance(0.2)
      click(get(:navigation_buttons).fetch(:categories))
      advance(0.04)
      check("all categories fade when arriving from #{from}", visual(get(:page_view), :opacity).between?(0.1, 0.99))
      advance(0.2)
      check("categories settle to one interactive page from #{from}", get(:page_transition).views.size == 1 && !get(:motion).active?)
    end
    labels = -> { @automation.layout.select { |node| node[:kind] == "Para" }.map { |node| node[:text] } }
    names = all.map { |category| category.fetch("name") }
    check("the full category list is available", (labels.call & names).size == 105)
    shot("categories-full")
    viewport = @automation.rect_of!(get(:results).linkable_id)
    @automation.wheel(30_000, x: viewport.x + viewport.w / 2, y: viewport.y + 30)
    last = all.last
    item = @automation.layout.find { |node| node[:kind] == "Para" && node[:text] == last.fetch("name") }
    check("scrolling reaches the final category", item && item[:y] >= viewport.y && item[:y] + item[:h] <= viewport.y + viewport.h)
    shot("categories-bottom")

    field = @automation.layout.find { |node| node[:kind] == "EditLine" }
    @automation.click({ id: field.fetch(:id) })
    @automation.type("مَصْطَلَح")
    check("Arabic filtering finds the last category including diacritics", (labels.call & names) == [last.fetch("name")])
    @automation.key("control_a")
    @automation.type("لايوجدتصنيفبهذاالاسم")
    check("unmatched category searches show an empty state", labels.call.include?("لا توجد تصنيفات مطابقة") && (labels.call & names).empty?)
    @automation.key("control_a")
    @automation.key("backspace")
    check("clearing the filter restores all categories", (labels.call & names).size == 105)
    @automation.wheel(30_000, x: viewport.x + viewport.w / 2, y: viewport.y + 30)
    @automation.click({ text: last.fetch("name") })
    check("the final category opens its scoped books", get(:screen) == :browse && get(:scope_filters)[:category] == last.fetch("id"))
    advance(0.2)

    @app.navigate(:categories)
    advance(0.03)
    @app.navigate(:home)
    advance(0.03)
    @app.navigate(:categories)
    advance(0.2)
    check("interrupted full-list navigation leaves no stale page", get(:screen) == :categories &&
      get(:page_transition).views.size == 1 && (labels.call & names).size == 105 && !get(:motion).active?)
    MotionPreference.set(@app, reduced: true)
    @app.navigate(:home)
    @app.navigate(:categories)
    check("full-list navigation respects OS Reduce Motion", visual(get(:page_view), :opacity) == 1.0 && !get(:motion).active?)
    set(categories: AlignmentVerification::CATEGORIES)
    @app.navigate(:home)
    MotionPreference.set(@app, reduced: false)
  end

  def nested_filters
    @app.navigate(:home)
    advance(0.2)
    click(get(:action_views).fetch(:filters))
    advance(0.2)
    panel, backdrop = get(:dialog_panel), get(:dialog_backdrop)
    bounds = @automation.rect_of!(panel.linkable_id)
    previous = get(:dialog_transition).current
    click(get(:action_views).fetch([:filter, :library]))
    current = get(:dialog_transition).current
    check("nested filters preserve the popup shell and backdrop", get(:dialog_panel).equal?(panel) && get(:dialog_backdrop).equal?(backdrop) && visual(backdrop, :opacity) == 1.0)
    check("nested filters enter from the RTL forward direction", visual(current, :displace_left) == -8 && previous.style[:inert])
    check("nested filters provide a back action", get(:action_views).key?(:dialog_back))
    advance(0.06)
    rect = @automation.rect_of!(panel.linkable_id)
    check("nested filters keep their anchor and width", rect.x == bounds.x && rect.y == bounds.y && rect.w == bounds.w)
    check("nested filters crossfade their content", visual(current, :opacity).between?(0.1, 0.99) && visual(previous, :opacity).between?(0.01, 0.9))
    color = @app.card_color.delete_prefix("#").scan(/../).map { |channel| channel.to_i(16) }
    check("the shared popup surface remains opaque during the handoff", @automation.pixel(rect.x + rect.w / 2, rect.y + 52).first(3) == color)
    shot("nested-filter-midway")
    opacity = visual(current, :opacity)
    click(get(:action_views).fetch(AlignmentVerification::LIBRARIES.first.fetch("name")))
    check("selecting during entrance reverses smoothly to the parent", get(:dialog)[:type] == :filters && visual(current, :opacity) == opacity && visual(get(:dialog_transition).current, :displace_left) == 8)
    check("nested selection returns focus and preserves the unapplied draft", @automation.focused == get(:action_views).fetch([:filter, :library]).linkable_id &&
      get(:dialog).dig(:filters, :library) == AlignmentVerification::LIBRARIES.first.fetch("id") && get(:filters).empty?)
    advance(0.2)
    check("nested transition releases old views and unused height", get(:dialog_transition).views.size == 1 && @automation.rect_of!(panel.linkable_id).h == bounds.h)

    click(get(:action_views).fetch([:filter, :category]))
    advance(0.04)
    current = get(:dialog_transition).current
    opacity = visual(current, :opacity)
    @app.render_dialog
    check("picker refresh preserves its transition instead of restarting", get(:dialog_transition).current.equal?(current) && visual(current, :opacity) == opacity)
    @automation.key("escape")
    @automation.key("escape")
    advance(0.2)
    check("rapid back and close remove every nested view and restore input", !@app.dialog_active? && get(:dialog_transition).views.empty? && !get(:content_layer).style[:inert])

    MotionPreference.set(@app, reduced: true)
    click(get(:action_views).fetch(:filters))
    click(get(:action_views).fetch([:filter, :author]))
    check("author picker uses the same filter width", @automation.rect_of!(get(:dialog_panel).linkable_id).w == bounds.w)
    check("reduced-motion nested navigation has no leaving views", get(:dialog_transition).views.size == 1 && visual(get(:dialog_transition).current, :opacity) == 1.0)
    @automation.resize(800, 700)
    @app.tick
    check("resizing a nested picker retains its parent width", @automation.rect_of!(get(:dialog_panel).linkable_id).w == bounds.w)
    @automation.key("escape")
    @automation.key("escape")
    MotionPreference.set(@app, reduced: false)
  end

  def notifications
    @app.navigate(:home)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    @app.notify_download(book: AlignmentVerification::BOOKS.first, status: :done)
    @app.update_notification
    advance(0.05)
    check("notification fades without stealing keyboard focus", visual(get(:notification_layer), :opacity).between?(0.1, 0.99) &&
      @automation.focused == field.linkable_id)
    @automation.type(" والعمل")
    check("typing continues during a notification entrance", field.text == "العلم والعمل")
    shot("notification-midway")
    advance(0.20)
    @app.dismiss_notification
    advance(0.15)
    check("notification exit clears its hit area and timer", get(:notification_layer).style[:width].zero? && !get(:motion).active?)
  end

  def preferences
    check("status bar has no motion settings button", !@automation.a11y.to_s.include?("إعدادات الحركة"))
    get(:store).save_preference("motion", "full")
    MotionPreference.set(@app, reduced: true)
    check("OS Reduce Motion takes precedence over a former saved override", get(:motion).reduced)
    @app.open_dialog(:shortcuts)
    check("reduced motion opens immediately", get(:dialog_panel).style[:opacity] == 1.0 && !get(:motion).active?)
    @app.close_dialog
    get(:store).save_preference("motion", "reduced")
    MotionPreference.set(@app, reduced: false)
    check("turning off OS Reduce Motion restores animation despite old settings", !get(:motion).reduced)
    @app.open_dialog(:share)
    advance(0.04)
    @app.close_dialog
    MotionPreference.set(@app, reduced: true)
    check("changing the preference during exit completes cleanup", !@app.dialog_active? && !get(:motion).active? &&
      !get(:content_layer).style[:inert])
    MotionPreference.system(@app)
    check("system preference is queried through the native runtime", get(:motion).reduced == @app.reduced_motion?)
  end
end
