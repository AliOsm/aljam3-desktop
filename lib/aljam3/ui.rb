# frozen_string_literal: true

require_relative "pdf"
require_relative "ui/theme"
require_relative "ui/components"
require_relative "ui/catalog"
require_relative "ui/reader"
require_relative "ui/book_search"
require_relative "ui/dialogs"
require_relative "ui/browsing"

module Aljam3
  module UI
    include Theme, Components, Catalog, Reader, BookSearch, Dialogs, Browsing

    def setup
      %w[NotoNaskhArabicUI Cairo Kitab].each { |name| font(File.join(ROOT, "assets/fonts/#{name}.ttf")) }
      directory = Aljam3.data_directory
      @store = Store.new(File.join(directory, "library.sqlite3"))
      @theme = @store.preference("theme", system_theme.to_s).to_sym
      apply_theme
      @api = API.new(base_url: ENV.fetch("ALJAM3_API_URL", "https://aljam3.com"))
      @library = Library.new(api: @api, store: @store)
      @downloader = Downloader.new(api: @api, store: @store, directory: File.join(directory, "books"))
      @reading = Reading.new(api: @api, store: @store, downloader: @downloader)
      @pdf = PDF.new(cache: File.join(directory, "renders"))
      @network_worker, @download_worker, @render_worker, @page_worker = Array.new(4) { Worker.new }
      @workers = [@network_worker, @download_worker, @render_worker, @page_worker]
      @updates, @downloads = Queue.new, {}
      @downloaded_ids = @store.downloaded_ids
      @categories, @libraries = @store.preference("categories", []), @store.preference("libraries", [])
      @screen, @mode, @query = :home, :content, ""
      @filters, @expanded = {}, {}
      @request_number, @render_number, @page_request = 0, 0, 0
      @busy = false
      draw_window
      every(0.1) { tick }
      keypress do |key|
        if key == :escape
          close_dialog if @dialog
        elsif %i[control_f alt_f].include?(key)
          if @dialog&.dig(:type) == :book_search
            @book_query_field&.focus
          elsif !@dialog
            @screen == :reader ? open_book_search : @query_field&.focus
          end
        end
      end
      finish do
        @workers.each(&:close)
        @reading.close
        @store.close
      end
      @network_worker.submit(-> { [@library.categories, @library.libraries] }) do |data, error|
        next if error

        @categories, @libraries = data
        draw_window if %i[home categories].include?(@screen) || @dialog&.dig(:type) == :filters
      end
    end

    def tick
      @workers.each(&:drain)
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
      if !@dialog && !@error && @results && @result && !@busy && !@loading_more && @results.scroll_max > 0 &&
          @results.scroll_top >= @results.scroll_max - 160 && next_result_page
        request_catalog(page: next_result_page, append: true)
      end
    end

    def draw_window
      scroll = @dialog_scroll&.fetch(:results) || @results&.scroll_top || 0
      text_scroll = @dialog_scroll&.fetch(:text) || @text_surface&.scroll_top || 0
      pdf_scroll = @dialog_scroll&.fetch(:pdf) || @pdf_surface&.scroll_top || 0
      @viewport = [width, height]
      @progress_views = {}
      @main_width = [width - 32, 1120].min
      @content_height = [height - 100, 260].max
      @drawing_dialog = false
      clear do
        background paper
        if @screen == :reader
          draw_reader
        else
          navigation
          stack(left: (width - @main_width) / 2, top: 80, width: @main_width, height: @content_height) do
            case @screen
            when :downloads then draw_downloads
            when :home then @query.strip.empty? ? draw_home : draw_catalog
            when :categories then draw_categories
            when :opening then empty_state("جارٍ فتح الكتاب…", "نحمّل الصفحة المطلوبة للقراءة.")
            else draw_catalog
            end
          end
        end
        draw_dialog if @dialog
      end
      @results.scroll_top = scroll if @results
      @text_surface.scroll_top = text_scroll if @screen == :reader && @text_surface
      @pdf_surface.scroll_top = pdf_scroll if @screen == :reader && @pdf_surface
    end

    def navigation
      stack(left: 0, top: 0, width: width, height: 60) do
        background paper
        line 0, 59, width, 59, stroke: line_color
        flow(left: 16, top: 12, width: 264, height: 36) do
          icon_button(@theme == :dark ? "sun" : "moon", @theme == :dark ? "الوضع الفاتح" : "الوضع الداكن") { toggle_theme }
          navigation_button("التنزيلات", :downloads, width: 90)
          navigation_button("كتبي المحمّلة", :saved, width: 130)
        end
        flow(left: width - 404, top: 12, width: 326, height: 36) do
          navigation_button("الكتب", :browse, width: 68)
          navigation_button("المؤلفون", :authors, width: 80)
          navigation_button("التصنيفات", :categories, width: 90)
          navigation_button("الرئيسية", :home, width: 88)
        end
        image(asset_path("brand", "aljam3"), left: width - 64, top: 12, width: 45, height: 35,
          alt: "الجامع · الرئيسية") { navigate(:home) unless @dialog }
      end
    end

    def navigation_button(label, screen, width:)
      action(label, width:, variant: :ghost, selected: @screen == screen) { navigate(screen) }
    end

    def navigate(screen, filters: {}, label: nil)
      @screen, @query, @mode = screen, "", screen == :authors ? :authors : :content
      @result = @results = @error = @dialog = @dialog_scroll = nil
      @filters, @expanded, @filters_by_mode, @scope_label = filters, {}, {}, label
      @mode = :books unless filters.empty?
      @request_number += 1
      @render_number += 1
      @page_request += 1
      @busy = @loading_more = false
      %i[browse saved authors].include?(screen) ? request_catalog : draw_window
    end

    def request_catalog(page: 1, append: false)
      @request_number += 1
      request_number = @request_number
      query, screen, mode, filters = @query.strip, @screen, @mode, @filters.dup
      if append
        @loading_more = true
      else
        @busy, @error, @result, @results = true, nil, nil, nil
        @expanded = {}
        draw_window
      end
      work = -> do
        if mode == :authors || screen == :authors
          @library.authors(query:, page:)
        elsif mode == :content && (!query.empty? || !filters.empty?) && screen != :saved
          @library.search(query, **filters, page:)
        else
          @library.browse(query:, **filters, page:, downloaded: screen == :saved)
        end
      end
      @network_worker.submit(work) do |result, error|
        next unless @request_number == request_number && @screen == screen

        @busy = @loading_more = false
        if error
          @error = error_message(error)
        else
          if append && @result&.source == result.source
            key = result_key(result)
            data = result.data.merge(key => (@result.data.fetch(key) + result.data.fetch(key)).uniq { |item| item.fetch("id") })
            result = Result.new(data, result.source, result.notice)
          end
          @result, @source = result, result.source
        end
        draw_window
      end
    end

    def result_key(result = @result) = %w[pages authors books].find { |key| result.data.key?(key) }

    def next_result_page
      pagination = @result.data.fetch("pagination")
      current = pagination.fetch("current_page")
      current + 1 if current < pagination.fetch("total_pages")
    end

    def source_label
      return "جارٍ الاتصال…" if @busy

      { online: "متصل بالجامع", offline: "دون اتصال · الفهرس المحفوظ", local: "الخدمة غير متاحة · الفهرس المحفوظ",
        downloaded: "محفوظ على جهازك" }.fetch(@source, "الجامع لسطح المكتب")
    end

    def queue_download(book)
      id = book.fetch("id")
      return if %i[queued downloading].include?(@downloads.dig(id, :status))

      @downloads[id] = { book:, status: :queued, fraction: 0, message: "في قائمة الانتظار" }
      draw_window
      @download_worker.submit(-> { @downloader.call(id) { |fraction, message| @updates << [id, fraction, message] } }) do |_downloaded, error|
        if error
          @downloads.fetch(id).merge!(status: :failed, message: error_message(error))
        else
          @downloads.fetch(id).merge!(status: :done, fraction: 1, message: "اكتمل · متاح دون اتصال")
          @downloaded_ids = @store.downloaded_ids
        end
        draw_window
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
  end
end
