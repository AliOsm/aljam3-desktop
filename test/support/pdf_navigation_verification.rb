# frozen_string_literal: true

require "timeout"
require "tmpdir"
require_relative "range_pdf"

# Drive the real reader and workers while PDFium is inside an image callback.
# Only the catalogue/text responses are fixtures; PDFs use real HTTP ranges.
class PDFNavigationVerification
  class ReadGate
    attr_reader :cancelled

    def initialize
      @entered, @release = Queue.new, Queue.new
      @armed, @cancelled = true, 0
    end

    def entered? = !@entered.empty?
    def release = @release.push(true)

    def read(check)
      return yield(check) unless @armed

      @armed = false
      checks = 0
      yield(-> {
        checks += 1
        if checks == 2
          @entered.push(true)
          @release.pop
        end
        check.call
      })
    rescue Aljam3::PDF::Cancelled
      @cancelled += 1
      raise
    end
  end

  def initialize(app, automation)
    @app, @automation = app, automation
  end

  def call
    @app.choose_motion("reduced")
    drain(:network_worker)
    @books = {}
    books = @books
    api = get(:api)
    api.define_singleton_method(:connection) { :online }
    api.define_singleton_method(:book) { |id| books.fetch(id) }
    api.define_singleton_method(:page) do |file, number|
      { "id" => file * 10 + number, "number" => number, "content" => "نص الصفحة #{number}" }
    end
    @app.tick
    get(:store).save_preference("reader", { "mode" => "split" })
    reading = get(:reading)
    verifier = self
    reading.define_singleton_method(:pdf_source) do |book_id, file|
      source = super(book_id, file)
      verifier.observe(source)
      source
    end

    Dir.mktmpdir("aljam3-navigation-") do |directory|
      data = RangePDF.image_document(pages: 6)
      path = File.join(directory, "reference.pdf")
      File.binwrite(path, data)
      reference = Aljam3::PDF.new(cache: File.join(directory, "reference"))
      RangePDF.serve(data) do |url, requests|
        scenarios = %i[close switch_book page zoom] * 5
        scenarios.each_with_index do |scenario, index|
          @app.navigate(:home)
          cache = File.join(directory, "renders-#{index}")
          @app.instance_variable_set(:@pdf, Aljam3::PDF.new(cache:))
          @gate = ReadGate.new
          first, second = [920_000 + index * 2, 920_001 + index * 2].map { |id| book(id, url) }
          @app.open_book(first)
          wait_until { @gate.entered? }
          raise "The paused page was already displayed" if get(:reader)[:image]

          expected_book = first
          case scenario
          when :close
            @app.close_reader
            @gate.release
            drain(:render_worker)
            raise "Closing a book restored an obsolete reader" if get(:screen) == :reader
            raise "Cancelled page was cached" unless Dir.glob(File.join(cache, "*")).empty?

            @app.open_book(first)
            wait_until { get(:screen) == :reader }
          when :switch_book
            @app.open_book(second)
            wait_until { get(:screen) == :reader && get(:reader).dig(:book, "id") == second.fetch("id") }
            expected_book = second
          when :page
            [6, 2, 5, 3].each { |number| @app.turn_page(number) }
          when :zoom
            [0.25, 0.25, -0.5, 0.25].each { |change| @app.change_zoom(change) }
          end
          # Queue several superseding renders before allowing the obsolete one
          # to return from C++. Only the final page and zoom may reach the UI.
          @app.turn_page(6)
          @app.change_zoom(1.25 - get(:reader).fetch(:zoom))
          @gate.release unless scenario == :close
          drain(:render_worker)
          drain(:page_worker)
          wait_until { get(:page_image) }
          reader = get(:reader)
          raise "Cancellation did not reach the image callback" unless @gate.cancelled == 1
          raise "An obsolete book or page replaced the requested one" unless reader.dig(:book, "id") == expected_book.fetch("id") && reader[:number] == 6 && reader[:page].fetch("number") == 6
          raise "Obsolete error reached the reader" if reader[:pdf_error] || reader[:text_error]
          image = reader.fetch(:image)
          width = ((get(:pdf_width) - 32) * 1.25 * 1.5).to_i.clamp(240, 2400)
          raise "An obsolete zoom replaced the requested one" unless image.width == width
          local = reference.render(path, page: 6, width:)
          raise "Latest page pixels differ from the local PDF" unless File.binread(image.path) == File.binread(local.path)
          raise "The UI is displaying an obsolete image" unless get(:page_image).url == image.path
        end
        @automation.wait_frames
        { cycles: scenarios.size, cancelled_image_reads: scenarios.size, scenarios: scenarios.uniq,
          latest_page: 6, latest_zoom: 1.25, latest_pixels_match: true, range_requests: requests.size }
      end
    end
  ensure
    @gate&.release
  end

  def observe(source)
    return if source.instance_variable_defined?(:@verification_gate)

    gate = @gate
    source.instance_variable_set(:@verification_gate, gate)
    source.define_singleton_method(:read) do |offset, length, check:|
      if length > Aljam3::RemotePDF::BLOCK_SIZE
        gate.read(check) { |checked| super(offset, length, check: checked) }
      else
        super(offset, length, check:)
      end
    end
  end

  private

  def get(name) = @app.instance_variable_get("@#{name}")

  def wait_until
    Timeout.timeout(15) do
      loop do
        @app.tick
        break if yield

        sleep 0.005
      end
    end
  end

  def drain(worker)
    ready = false
    get(worker).submit(-> { nil }) { ready = true }
    wait_until { ready }
  end

  def book(id, url)
    @books[id] = { "id" => id, "title" => "كتاب الاختبار #{id}", "pages_count" => 6, "files_count" => 1,
      "files" => [{ "id" => id, "name" => "الكتاب", "pages_count" => 6, "urls" => { "pdf" => "#{url}?book=#{id}" } }] }
  end
end
