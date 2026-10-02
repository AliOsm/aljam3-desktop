# frozen_string_literal: true

require_relative "pdf"
require_relative "ui/theme"
require_relative "ui/components"
require_relative "ui/catalog"
require_relative "ui/reader"
require_relative "ui/book_search"
require_relative "ui/dialogs"
require_relative "ui/browsing"
require_relative "ui/downloads"
require_relative "ui/reader_tools"

module Aljam3
  module UI
    include Theme, Components, Catalog, Reader, BookSearch, Dialogs, Browsing, DownloadScreen, ReaderTools

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
      @network_worker, @render_worker, @page_worker, @export_worker = Array.new(4) { Worker.new }
      @workers = [@network_worker, @render_worker, @page_worker, @export_worker]
      @download_queue = Downloads.new(store: @store, downloader: @downloader)
      @downloads = @download_queue.entries
      @downloaded_ids = @store.downloaded_ids
      @categories, @libraries = @store.preference("categories", []), @store.preference("libraries", [])
      @screen, @mode, @query = :home, :content, ""
      @search_scope, @connection = :all, @api.connection
      @filters, @expanded = {}, {}
      @request_number, @render_number, @page_request = 0, 0, 0
      @busy = false
      draw_window
      every(0.1) { tick }
      keypress do |key|
        if key == :escape
          @dialog ? close_dialog : clear_reader_matches if @dialog || @screen == :reader
        elsif %i[control_f alt_f].include?(key)
          if @dialog&.dig(:type) == :book_search
            @book_query_field&.focus
          elsif !@dialog
            @screen == :reader ? open_book_search : @query_field&.focus
          end
        elsif @screen == :reader && !@dialog
          reader_keypress(key)
        end
      end
      motion { |x, _y| resize_reader_split(x) if @split_drag && !@dialog }
      release do
        if @split_drag
          @split_drag = false
          save_reader_options
          render_pdf if reader_pdf?
        end
      end
      finish do
        @download_queue.close
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
      redraw = @download_queue.tick
      @downloaded_ids = @store.downloaded_ids if redraw
      if @connection != @api.connection
        @connection = @api.connection
        redraw = true
      end
      draw_window if redraw && !@split_drag
      @progress_views.each do |id, view|
        next unless (download = @downloads[id])

        view.fetch(:bar).fraction = download.fetch(:fraction)
        view.fetch(:label).text = download_message(download)
      end
      if @viewport != [width, height]
        draw_window
        render_pdf if reader_pdf?
      end
      catalog = %i[browse saved authors].include?(@screen) || (@screen == :home && !@query.empty?)
      if catalog && !@dialog && !@error && @results && @result && !@busy && !@loading_more && @results.scroll_max > 0 &&
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
          connection_strip
          @content_height -= 24
          stack(left: (width - @main_width) / 2, top: 104, width: @main_width, height: @content_height) do
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
      @search_scope = screen == :saved ? :downloaded : :all
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
      downloaded = @search_scope == :downloaded
      if append
        @loading_more = true
      else
        @busy, @error, @result, @results = true, nil, nil, nil
        @expanded = {}
        if query.empty? && mode != :authors
          data = @store.catalog(**filters, downloaded:)
          @result = Result.new(data, downloaded ? :downloaded : :cached, nil) unless data.fetch("books").empty?
          @source = @result.source if @result
        end
        draw_window
      end
      work = -> do
        if mode == :authors || screen == :authors
          @library.authors(query:, page:, downloaded:)
        elsif mode == :content && (!query.empty? || !filters.empty?)
          @library.search(query, **filters, page:, downloaded:)
        else
          @library.browse(query:, **filters, page:, downloaded:)
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
      return @result ? "المحفوظ على جهازك · جارٍ التحديث…" : "جارٍ البحث…" if @busy

      { online: "متصل بالجامع", offline: "دون اتصال · الفهرس المحفوظ", local: "الخدمة غير متاحة · الفهرس المحفوظ",
        downloaded: "في كتبك المحمّلة فقط", cached: "الفهرس المحفوظ على جهازك" }.fetch(@source, "الجامع لسطح المكتب")
    end

    def queue_download(book)
      @download_queue.enqueue(book)
      draw_window
    end

    def connection_strip
      message = case @connection
                when :offline then "دون اتصال · كتبك المحمّلة متاحة للقراءة والبحث."
                when :unavailable then "المكتبة غير متاحة الآن · يمكنك استخدام كتبك المحمّلة."
                when :online then "متصل بالجامع · نزّل الكتب لتحتفظ بها دون اتصال."
                else "مكتبتك المحفوظة جاهزة · جارٍ التحقق من الاتصال…"
                end
      para message, left: 160, top: 73, width: width - 180, size: 13, stroke: muted
      if %i[offline unavailable].include?(@connection)
        action("إعادة الاتصال", left: 16, top: 64, width: 126, variant: :ghost) { refresh_connection }
      end
    end

    def refresh_connection
      @network_worker.submit(-> { [@library.categories, @library.libraries] }) do |data, _error|
        @categories, @libraries = data if data
        %i[browse saved authors].include?(@screen) ? request_catalog : draw_window
      end
    end

    def error_message(error)
      warn error.full_message
      case error
      when RangeUnsupportedError then "لا يدعم مصدر الكتاب القراءة المباشرة. يمكنك تنزيله من صفحة التنزيلات."
      when RemoteFileChangedError then "تغيّر ملف الكتاب على المصدر. أعد تحميل الصفحة."
      when ConnectionError then "تعذّر الاتصال. تحقق من الإنترنت ثم أعد المحاولة."
      when ResponseError then "تعذّر الوصول إلى المكتبة (#{error.status}). أعد المحاولة لاحقًا."
      when Errno::ENOSPC then "لا توجد مساحة كافية لتنزيل الكتاب."
      else "تعذّر إكمال العملية. أعد المحاولة."
      end
    end
  end
end
