# frozen_string_literal: true

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
    @app.choose_motion("full")
    AlignmentVerification.seed(get(:store))
    set(categories: AlignmentVerification::CATEGORIES, libraries: AlignmentVerification::LIBRARIES)
    reader
    overlays
    controls
    notifications
    preferences
    { passed: true, checks: @checks }
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")
  def set(**values) = values.each { |key, value| @app.instance_variable_set("@#{key}", value) }
  def advance(seconds) = @automation.advance(seconds)
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
    check("entrance starts transparent", panel.style[:opacity].zero?)
    shot("popup-start")
    advance(0.05)
    check("popup fades and moves toward its anchor", panel.style[:opacity].between?(0.1, 0.99) &&
      (panel.style[:top] - get(:dialog_rest_top)).abs.between?(0.1, 5))
    shot("popup-midway")
    @automation.key("escape")
    opacity = panel.style[:opacity]
    check("Escape reverses the in-progress entrance", !get(:dialog) && get(:closing_dialog) && !opacity.zero?)
    @automation.key("escape")
    advance(0.04)
    check("exit continues smoothly from the interrupted value", panel.style[:opacity] < opacity)
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
    midway = toggle.style[:switch_position]
    check("switch thumb has intermediate positions", midway.between?(0.1, 0.9))
    click(toggle)
    check("rapid switch reversal has no visual jump", toggle.style[:switch_position] == midway)
    advance(0.15)
    check("switch ends at the latest requested value", toggle.style[:switch_position] == 1.0)
    @app.close_dialog
    advance(0.15)
    control = get(:copy_button)
    @automation.hover(control.linkable_id)
    advance(0.04)
    check("button hover interpolates its color", control.style[:hover_amount].between?(0.1, 0.99))
    @automation.leave(control.linkable_id)
    advance(0.15)
    check("button leave settles and stops ticking", control.style[:hover_amount].zero? && !get(:motion).active?)
    bar = get(:activity_progress)
    @app.smooth_progress(bar, 0.7)
    advance(0.05)
    check("progress advances toward actual progress without overshooting", bar.fraction.positive? && bar.fraction < 0.7)
    @app.smooth_progress(bar, 0.9)
    advance(0.20)
    check("progress settles at the latest reported value", bar.fraction == 0.9 && !get(:motion).active?)
  end

  def notifications
    @app.navigate(:home)
    field = get(:query_field)
    click(field)
    @automation.type("العلم")
    @app.notify_download(book: AlignmentVerification::BOOKS.first, status: :done)
    @app.update_notification
    advance(0.05)
    check("notification fades without stealing keyboard focus", get(:notification_layer).style[:opacity].between?(0.1, 0.99) &&
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
    @app.open_dialog(:motion_settings)
    advance(0.25)
    click(get(:action_views).fetch(:motion))
    advance(0.20)
    @automation.click({ text: "تقليل الحركة" })
    check("motion setting is saved and returns to its parent dialog", get(:motion).reduced &&
      get(:store).preference("motion") == "reduced" && get(:dialog)&.dig(:type) == :motion_settings)
    shot("motion-settings")
    @app.close_dialog
    check("reduced motion closes immediately", !@app.dialog_active? && !get(:motion).active?)
    @app.open_dialog(:shortcuts)
    check("reduced motion opens immediately", get(:dialog_panel).style[:opacity] == 1.0 && !get(:motion).active?)
    @app.close_dialog
    @app.choose_motion("full")
    @app.open_dialog(:share)
    advance(0.04)
    @app.close_dialog
    @app.choose_motion("reduced")
    check("changing the preference during exit completes cleanup", !@app.dialog_active? && !get(:motion).active? &&
      !get(:content_layer).style[:inert])
    @app.choose_motion("system")
    check("system preference is queried through the native runtime", get(:motion).reduced == @app.reduced_motion?)
  end
end
