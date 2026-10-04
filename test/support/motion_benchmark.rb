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
        2_000.times do |index|
          check.call
          file.write(bytes)
          yield((index + 1).fdiv(2_000), "PDF", (index + 1) * bytes.size, 2_000 * bytes.size)
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
    intervals = []
    # Warm up shaped Arabic text before measuring transitions.
    14.times do |index|
      type = index.even? ? :reader_options : :share
      started = Time.now.to_f
      @app.open_dialog(type)
      pace(0.24)
      @app.close_dialog
      pace(0.14)
      intervals << [started, Time.now.to_f] if index >= 2
    end
    raise "Background transfer did not progress" unless queue.current&.fetch(:bytes, 0).to_i.positive?

    bytes = queue.current.fetch(:bytes)
    queue.close
    get(:ticker).remove
    @app.instance_variable_set(:@activity_button, nil)
    @app.instance_variable_set(:@activity_progress, nil)
    pace(0.3)
    raise "Animation timer survived settling" if get(:motion).active?

    { passed: true, ghost: ENV["SCARPE_NATIVE_GHOST"] == "1", intervals:, transfer_bytes: bytes,
      scene: "1160x820 split reader; real PDF page; long Arabic text; disk transfer and SQLite progress persistence" }
  ensure
    FileUtils.rm_f(File.join(@output, "transfer.bin"))
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")

  def pace(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      @service.pump.step
      @automation.frames if ENV["SCARPE_NATIVE_HEADLESS"] == "1"
    end
    @automation.wait_frames
  end
end
