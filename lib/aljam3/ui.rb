# frozen_string_literal: true

require_relative "pdf"
require_relative "ui/theme"
require_relative "ui/components"
require_relative "ui/catalog"
require_relative "ui/reader"
require_relative "ui/book_search"

module Aljam3
  module UI
    include Components, Catalog, Reader, BookSearch

    def setup
      %w[NotoNaskhArabicUI Cairo Kitab].each { |name| font(File.join(ROOT, "assets/fonts/#{name}.ttf")) }
      style(Shoes::Para, font: FONT, size: 17, stroke: INK, margin: 0, align: "right")
      style(Shoes::Button, font: FONT, size: 16, height: 36)
      style(Shoes::EditLine, font: "#{FONT} 18", height: 40, stroke: INK, fill: PAPER, border_color: LINE)

      directory = Aljam3.data_directory
      @store = Store.new(File.join(directory, "library.sqlite3"))
      @api = API.new(base_url: ENV.fetch("ALJAM3_API_URL", "https://aljam3.com"))
      @library = Library.new(api: @api, store: @store)
      @downloader = Downloader.new(api: @api, store: @store, directory: File.join(directory, "books"))
      @pdf = PDF.new(cache: File.join(directory, "renders"))
      @network_worker, @download_worker, @render_worker = Array.new(3) { Worker.new }
      @updates = Queue.new
      @downloads = {}
      @downloaded_ids = @store.downloaded_ids
      @categories = @store.preference("categories", [])
      @screen, @mode, @query = :browse, :content, ""
      @request_number, @render_number = 0, 0
      @busy = true
      draw_window
      every(0.1) { tick }
      keypress do |key|
        if %i[control_f alt_f].include?(key)
          @screen == :reader ? open_book_search : (@screen == :book_search ? @book_query_field : @query_field)&.focus
        elsif key == :escape
          close_picker if @screen == :picker
          close_book_search if @screen == :book_search
        end
      end
      finish do
        [@network_worker, @download_worker, @render_worker].each(&:close)
        @store.close
      end
      request_catalog
      @network_worker.submit(-> { @library.categories }) do |categories, error|
        next if error

        @categories = categories
      end
    end

    def tick
      [@network_worker, @download_worker, @render_worker].each(&:drain)
      until @updates.empty?
        id, fraction, message = @updates.pop
        next unless %i[queued downloading].include?(@downloads.fetch(id).fetch(:status))

        @downloads.fetch(id).merge!(fraction:, message:, status: :downloading)
        if (view = @progress_views[id])
          view.fetch(:bar).fraction = fraction
          view.fetch(:label).text = message
        end
      end
      if @viewport != [width, height]
        draw_window
        render_pdf if reader_pdf?
      end
    end

    def draw_window
      @viewport = [width, height]
      @progress_views = {}
      @main_width = [width - 48, 1120].min
      clear do
        background PAPER
        if @screen == :reader
          draw_reader
        else
          navigation
          top = 84
          @content_height = [height - top - 24, 260].max
          stack(left: (width - @main_width) / 2, top:, width: @main_width, height: @content_height) do
            case @screen
            when :downloads then draw_downloads
            when :picker then draw_picker
            when :book_search then draw_book_search
            else draw_catalog
            end
          end
        end
      end
    end

    def navigation
      stack(left: 0, top: 0, width: width, height: 60) do
        background PAPER
        line 0, 59, width, 59, stroke: LINE
        status_note(source_label, left: 24, top: 16, width: 160)
        flow(left: width - 430, top: 12, width: 336, height: 36) do
          navigation_button("التنزيلات", :downloads, width: 96)
          navigation_button("كتبي المحمّلة", :saved, width: 136)
          navigation_button("المكتبة", :browse, width: 96)
        end
        image(File.join(ROOT, "assets/brand/aljam3.png"), left: width - 72, top: 12, width: 45, height: 35,
          alt: "الجامع · المكتبة") { navigate(:browse) }
      end
    end

    def navigation_button(label, screen, width:)
      current = @screen == :picker ? @picker.fetch(:return_screen) : @screen
      action(label, width:, variant: :ghost, selected: current == screen) { navigate(screen) }
    end

    def navigate(screen)
      @screen, @query, @mode, @result, @error, @category = screen, "", :content, nil, nil, nil
      @request_number += 1
      @render_number += 1
      @busy = screen != :downloads
      screen == :downloads ? draw_window : request_catalog
    end

    def request_catalog(page: 1)
      @request_number += 1
      request_number = @request_number
      query, category, screen, content = @query.dup, @category, @screen, searching_content?
      @busy, @error = true, nil
      draw_window
      work = -> do
        content ? @library.search(query, category:, page:) : @library.browse(query:, category:, page:, downloaded: screen == :saved)
      end
      @network_worker.submit(work) do |result, error|
        next unless @request_number == request_number && @screen == screen

        @busy = false
        if error
          @error = error_message(error)
        else
          @result, @source = result, result.source
        end
        draw_window
      end
    end

    def searching_content? = @screen == :browse && @mode == :content && !@query.strip.empty?
    def selected_category_label = @categories.find { |category| category.fetch("id") == @category }&.fetch("name") || "جميع التصنيفات"

    def open_picker(heading, choices, &selection)
      @picker = { heading:, choices:, selection:, return_screen: @screen, query: "" }
      @screen = :picker
      draw_window
    end

    def source_label
      if @screen == :book_search
        return "جارٍ البحث…" if @book_search[:busy]
        return @book_search[:result]&.source == :online ? "متصل بالجامع" : "بحث في الكتاب المحمّل"
      end
      return "جارٍ الاتصال…" if @busy

      case @source
      when :online then "متصل بالجامع"
      when :offline then "دون اتصال"
      when :local then "الخدمة غير متاحة"
      when :downloaded then "محفوظ على جهازك"
      else "الجامع لسطح المكتب"
      end
    end

    def queue_download(book, page_id: nil)
      id = book.fetch("id")
      return if %i[queued downloading].include?(@downloads.dig(id, :status))

      @downloads[id] = { book:, status: :queued, fraction: 0, message: "في قائمة الانتظار" }
      draw_window
      work = -> { @downloader.call(id) { |fraction, message| @updates << [id, fraction, message] } }
      @download_worker.submit(work) do |downloaded, error|
        if error
          @downloads.fetch(id).merge!(status: :failed, message: error_message(error))
        else
          @downloads.fetch(id).merge!(status: :done, fraction: 1, message: "اكتمل · متاح دون اتصال")
          @downloaded_ids = @store.downloaded_ids
        end
        if page_id && !error
          open_book(downloaded, page_id:)
        elsif !%i[reader book_search].include?(@screen)
          draw_window
        end
      end
    end

    def error_message(error)
      warn error.full_message
      case error
      when ConnectionError then "تعذّر الاتصال. تحقق من الإنترنت ثم أعد المحاولة."
      when ResponseError then "تعذّر الوصول إلى المكتبة (#{error.status}). أعد المحاولة لاحقًا."
      when Errno::ENOSPC then "لا توجد مساحة كافية لتنزيل الكتاب."
      else "تعذّر إكمال العملية. أعد المحاولة."
      end
    end

    def close_picker
      @screen = @picker.fetch(:return_screen)
      draw_window
      render_pdf if reader_pdf?
    end
  end
end
