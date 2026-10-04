# frozen_string_literal: true

require_relative "alignment_verification"

# The actual reader and Downloads worker, with controlled disk throughput instead
# of an Internet-dependent transfer. Ghost runs measure real OS presentation too.
class MotionBenchmark
  class Transfer
    def initialize(path) = @path = path
    def repair_download_sizes(after: 0) = nil

    def call(_id, check:)
      bytes = "a" * 65_536
      File.open(@path, "wb") do |file|
        10_000.times do |index|
          check.call
          file.write(bytes)
          yield((index + 1).fdiv(10_000), "PDF", (index + 1) * bytes.size, 10_000 * bytes.size)
          sleep 0.02
        end
      end
    end
  end

  def initialize(app, automation, output:)
    @app, @automation, @output = app, automation, output
    @service = Shoes::DisplayService.display_service
  end

  def call(pdf:)
    @app.choose_motion("full")
    store = get(:store)
    AlignmentVerification.seed(store)
    book = AlignmentVerification::BOOKS.first
    rendered = get(:pdf).render(pdf, page: 72, width: 1_200)
    @app.instance_variable_set(:@reader, { book:, files: book.fetch("files"), file: book.fetch("files").first,
      number: 72, zoom: 1.0, mode: :split, text_size: 21, tashkeel: true, split_ratio: 0.5,
      query: "", image: rendered, page: { "content" => "آدابُ الْعِلْمِ وأَهْلِهِ\n" * 100 } })
    @app.instance_variable_set(:@screen, :reader)
    @app.instance_variable_set(:@bookmarks, [])
    @app.draw_window
    @automation.wait_frames
    get(:download_queue).close
    queue = Aljam3::Downloads.new(store:, downloader: Transfer.new(File.join(@output, "transfer.bin")))
    @app.instance_variable_set(:@download_queue, queue)
    queue.enqueue(book.merge("id" => 999_999))
    @app.tick
    get(:ticker).remove
    @samples = []
    # Measure each active transition separately. Settled pauses must never count
    # as dropped frames, and the first opening matters as well as warm repeats.
    4.times do |round|
      @round = round
      %i[reader_options reader_menu share shortcuts bookmarks export].each do |type|
        measure("#{type}/open") { @app.open_dialog(type) }
        measure("#{type}/close") { @app.close_dialog }
      end
      @app.open_dialog(:reader_options)
      settle
      2.times do
        measure("switch") { @automation.click({ id: get(:tashkeel_switch).linkable_id }) }
      end
      @app.close_dialog
      settle
      control = get(:copy_button)
      measure("hover/enter") { @automation.hover(control.linkable_id) }
      measure("hover/leave") { @automation.leave(control.linkable_id) }
      measure("progress") { @app.smooth_progress(get(:activity_progress), round.even? ? 0.9 : 0.1) }
      measure("reader_options/ruby_busy") do
        @app.open_dialog(:reader_options)
        @service.child.flush
        started = Time.now.to_f
        sleep 0.09 # the renderer must keep presenting while Ruby is occupied
        @busy_interval = [started, Time.now.to_f]
      end
      @app.close_dialog
      settle
    end
    @app.navigate(:home)
    @app.instance_variable_set(:@categories, AlignmentVerification::CATEGORIES)
    @app.instance_variable_set(:@libraries, AlignmentVerification::LIBRARIES)
    4.times do |round|
      @round = round
      measure("filters/open") { @app.open_filters }
      measure("dropdown/open") do
        @app.open_dialog(:select, nested: true, choices: [["الجميع", nil], ["المحمّلة", :downloaded]],
          selected: nil, selection: ->(_) {})
      end
      measure("dropdown/close") { @app.close_dialog }
      measure("filters/close") { @app.close_dialog }
      measure("notification/open") do
        @app.notify_download(book:, status: :done)
        @app.update_notification
      end
      measure("notification/close") { @app.dismiss_notification }
    end
    raise "Background transfer did not progress" unless queue.current&.fetch(:bytes, 0).to_i.positive?

    bytes = queue.current.fetch(:bytes)
    queue.close
    get(:ticker).remove
    @app.instance_variable_set(:@activity_button, nil)
    @app.instance_variable_set(:@activity_progress, nil)
    pace(0.3)
    raise "Animation timer survived settling" if get(:motion).active?

    { passed: true, ghost: ENV["SCARPE_NATIVE_GHOST"] == "1", native_timing: @service.respond_to?(:transition),
      macos_activity: ENV.key?("DYLD_INSERT_LIBRARIES") && ENV.key?("ALJAM3_MOTION_ACTIVITY"),
      samples: @samples, transfer_bytes: bytes,
      scene: "1160x820 split reader; real PDF page; long Arabic text; disk transfer and SQLite progress persistence" }
  ensure
    FileUtils.rm_f(File.join(@output, "transfer.bin"))
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")

  def measure(name)
    @app.tick
    @busy_interval = nil
    started = Time.now.to_f
    yield
    finished = settle
    @samples << { name:, round: @round, started:, finished:, ruby_busy: @busy_interval }
  end

  def settle
    @service.child.flush # the real event loop flushes immediately after a handler
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    while get(:motion).active?
      raise "Animation did not settle" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      @service.pump.step
      @automation.frames if ENV["SCARPE_NATIVE_HEADLESS"] == "1"
    end
    finished = Time.now.to_f
    @automation.wait_frames
    finished
  end

  def pace(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      @service.pump.step
      @automation.frames if ENV["SCARPE_NATIVE_HEADLESS"] == "1"
    end
    @automation.wait_frames
  end
end
