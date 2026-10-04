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
require_relative "ui/feedback"
require_relative "ui/exports"
require_relative "ui/motion"
require_relative "ui/navigation"

module Aljam3
  module UI
    include Theme, Components, Catalog, Reader, BookSearch, Dialogs, Browsing, DownloadScreen, ReaderTools, Feedback, Exports, Motion, Navigation

    def setup
      %w[NotoNaskhArabicUI Thmanyah Kitab].each { |name| font(File.join(ROOT, "assets/fonts/#{name}.ttf")) }
      directory = Aljam3.data_directory
      @store = Store.new(File.join(directory, "library.sqlite3"))
      @theme = initial_theme
      apply_theme
      setup_motion
      @api = API.new(base_url: ENV.fetch("ALJAM3_API_URL", "https://aljam3.com"))
      @library = Library.new(api: @api, store: @store)
      @downloader = Downloader.new(api: @api, store: @store, directory: File.join(directory, "books"))
      @reading = Reading.new(api: @api, store: @store, downloader: @downloader)
      @pdf = PDF.new(cache: File.join(directory, "renders"))
      @network_worker, @render_worker, @page_worker, @export_worker = Array.new(4) { Worker.new }
      @workers = [@network_worker, @render_worker, @page_worker, @export_worker]
      @notifications = Notifications.new
      @file_operations = {}
      @download_queue = Downloads.new(store: @store, downloader: @downloader) { |download| notify_download(download) }
      @downloaded_ids = @store.downloaded_ids
      @categories, @libraries = @store.preference("categories", []), @store.preference("libraries", [])
      @screen, @mode, @query = :home, :content, ""
      @search_order = :relevance
      @search_scope, @connection = :all, @api.connection
      @filters, @scope_filters, @expanded = {}, {}, {}
      @request_number, @render_number, @page_request = 0, 0, 0
      @busy = false
      @search_pool_size = Store::Search::POOL_SIZE
      draw_window
      @ticker = every(0.1) { tick }
      @preference_ticker = every(2) { refresh_motion_preference if @motion_preference == "system" }
      keypress do |key|
        if [:browser_back, :"alt_[", :alt_left].include?(key)
          navigate_history(:back)
        elsif [:browser_forward, :"alt_]", :alt_right].include?(key)
          navigate_history(:forward)
        elsif key == :escape
          if dialog_active?
            close_dialog
          elsif @screen == :reader
            @page_field.text = @reader.fetch(:number).to_s if @page_field
            clear_reader_matches
          end
        elsif %i[control_f alt_f].include?(key)
          if @dialog&.dig(:type) == :book_search
            @book_query_field&.focus
          elsif !dialog_active?
            @screen == :reader ? open_book_search : @query_field&.focus
          end
        elsif @screen == :reader && !dialog_active?
          reader_keypress(key)
        end
      end
      motion { |x, _y| resize_reader_split(x) if @split_drag && !dialog_active? }
      release do
        if @split_drag
          @split_drag = false
          save_reader_options
          render_pdf if reader_pdf?
        end
      end
      finish do
        @ticker.remove
        @preference_ticker.remove
        @motion.cancel
        @download_queue.close
        @workers.each(&:close)
        @reading.close
        @store.close
      end
      @network_worker.submit(-> { [@library.categories, @library.libraries] }) do |data, error|
        next if error

        @categories, @libraries = data
        refresh_dialog if @dialog&.dig(:type) == :filters
        refresh_window if %i[home categories].include?(@screen)
      end
    end

    def tick
      @workers.each(&:drain)
      render_dialog if @dialog_redraw_pending && @dialog && !@editing_field
      refresh_download_state if @download_queue.tick
      if @connection != @api.connection
        @connection = @api.connection
        update_connection
      end
      if @catalog_refresh_pending && !@editing_field && !dialog_active? && !@notification_focus
        request_catalog
      end
      if @redraw_pending && !@split_drag && !@editing_field && !dialog_active? && !@notification_focus
        draw_window
        @redraw_pending = false
      end
      @progress_views.each do |id, view|
        next unless (download = @download_queue.entry(id))

        smooth_progress(view.fetch(:bar), download.fetch(:fraction))
        view.fetch(:label).text = download_message(download)
      end
      if @viewport != [width, height]
        draw_window
        render_pdf if reader_pdf?
      end
      tick_feedback
    end

    def draw_window
      @dialog[:scroll] = @dialog_results.scroll_top if @dialog && @dialog_results
      scroll = @results&.scroll_top || 0
      text_scroll = @text_surface&.scroll_top || 0
      pdf_scroll = @pdf_surface&.scroll_top || 0
      @progress_views = {}
      @main_width = @screen == :reader ? width - PAGE_MARGIN * 2 : [width - PAGE_MARGIN * 2, 1120].min
      @content_height = [height - PAGE_TOP - STATUS_HEIGHT - 16, 260].max
      draw_frame unless @frame_signature == [width, height, @theme]
      @motion.cancel(:content)
      @drawing_dialog = false
      @editing_field = nil
      @redraw_pending = false
      @action_views = @chrome_action_views.dup
      @last_content_focus = nil unless @chrome_action_views.value?(@last_content_focus)
      @results = @text_surface = @pdf_surface = @query_field = nil
      @page_view = @page_transition.replace(direction: @navigation_motion) do |view|
        if view
          view.clear { draw_page }
          view
        else
          @page_host.append do
            @page_view = stack(left: 0, top: 0, width: width, height: height - STATUS_HEIGHT) { draw_page }
          end
          @page_view
        end
      end
      @navigation_motion = nil
      @navigation_buttons.each { |screen, button| button.color = @screen == screen ? accent : "transparent" }
      @base_action_views = @action_views.dup
      @content_layer.inert = !!@dialog
      @dialog ? render_dialog : clear_dialog_view
      @action_views.merge!(@notification_action_views || {}) unless @dialog
      update_notification
      position_notification
      update_connection
      update_activity
      @results.scroll_top = scroll if @results
      @text_surface.scroll_top = text_scroll if @screen == :reader && @text_surface
      @pdf_surface.scroll_top = pdf_scroll if @screen == :reader && @pdf_surface
      restore_navigation_scroll
    end

    def draw_frame
      @page_transition&.clear
      clear_dialog_view if @dialog_layer
      @motion.cancel
      @viewport = [width, height]
      @frame_signature = [width, height, @theme]
      @chrome_width = [width - PAGE_MARGIN * 2, 1120].min
      @action_views, @navigation_buttons = {}, {}
      @drawing_chrome = true
      clear do
        background paper
        @content_layer = stack(left: 0, top: 0, width: width, height: height, inert: !!@dialog) do
          @page_host = stack(left: 0, top: 0, width: width, height: height - STATUS_HEIGHT)
          navigation
          connection_bar
        end
        @chrome_action_views = @action_views.dup
        @dialog_layer = stack(left: 0, top: 0, width: width, height: height, hidden: true, overlay: true)
        draw_feedback
      end
      @page_transition = ViewTransition.new(@motion, group: :navigation, overlay: true)
    ensure
      @drawing_chrome = false
    end

    def draw_page
      background paper
      if @screen == :reader
        draw_reader
      else
        stack(left: (width - @main_width) / 2 - SCROLL_GUTTER, top: PAGE_TOP,
          width: @main_width + SCROLL_GUTTER, padding_left: SCROLL_GUTTER, height: @content_height) do
          case @screen
          when :downloads then draw_downloads
          when :home then @query.strip.empty? ? draw_home : draw_catalog
          when :categories then draw_categories
          when :opening then empty_state("جارٍ فتح الكتاب…", "نحمّل الصفحة المطلوبة للقراءة.")
          else draw_catalog
          end
        end
      end
    end

    def refresh_window
      @editing_field || dialog_active? ? @redraw_pending = true : draw_window
    end

    def navigation
      stack(left: 0, top: 0, width: width, height: 60) do
        background paper
        line 0, 59, width, 59, stroke: line_color
        row(left: (width - @chrome_width) / 2, top: 12, width: @chrome_width) do
          image(asset_path("brand", "aljam3"), width: 52, height: 35, margin_right: 8,
            alt: "الجامع · الرئيسية") { navigate(:home) unless @dialog }
          navigation_button("الرئيسية", :home, width: 76)
          navigation_button("التصنيفات", :categories, width: 88)
          navigation_button("المؤلفون", :authors, width: 80)
          navigation_button("الكتب", :browse, width: 68)
          stack(width: -606, height: 1)
          navigation_button("كتبي المحمّلة", :saved, width: 116)
          navigation_button("التنزيلات", :downloads, width: 90)
          icon_button(@theme == :dark ? "sun" : "moon", @theme == :dark ? "الوضع الفاتح" : "الوضع الداكن") { toggle_theme }
        end
      end
    end

    def navigation_button(label, screen, width:)
      @navigation_buttons[screen] = action(label, width:, variant: :ghost, selected: @screen == screen) { navigate(screen) }
    end

    def navigate(screen, filters: {}, label: nil)
      remember_location unless @screen == screen && @filters == filters && @query.empty?
      @store.cancel_search
      @navigation_motion = 0 if @screen != screen || @filters != filters || !@query.empty?
      @screen, @query, @mode = screen, "", screen == :authors ? :authors : :content
      @search_scope = screen == :saved ? :downloaded : :all
      @result = @results = @error = @dialog = @dialog_scroll = nil
      @catalog_refresh_pending = false
      @filters, @scope_filters, @expanded, @scope_label = filters.dup, filters.dup.freeze, {}, label
      @search_pool_size, @search_signature = Store::Search::POOL_SIZE, nil
      @mode = :books unless filters.empty?
      @request_number += 1
      @render_number += 1
      @page_request += 1
      @busy = false
      %i[browse saved authors].include?(screen) ? request_catalog : draw_window
    end

    def request_catalog(page: 1, expand: false)
      @catalog_refresh_pending = false
      @editing_field = nil
      signature = [@query.strip, @screen, @mode, @filters.dup, @search_scope, @search_order]
      @search_pool_size = Store::Search::POOL_SIZE if @search_signature != signature
      @search_signature = signature
      @search_pool_size += Store::Search::POOL_SIZE if expand
      @store.cancel_search if @busy
      @request_number += 1
      request_number = @request_number
      query, screen, mode, filters = @query.strip, @screen, @mode, @filters.dup
      @result_query = query
      downloaded = @search_scope == :downloaded
      order = @search_order
      pool_size = @search_pool_size
      @busy, @error, @result, @results = true, nil, nil, nil
      @expanded = {}
      if query.empty? && mode != :authors
        data = @store.catalog(**filters, page:, downloaded:)
        @result = Result.new(data, downloaded ? :downloaded : :cached, nil) unless data.fetch("books").empty?
        @source = @result.source if @result
      end
      draw_window
      work = -> do
        next unless @request_number == request_number

        if mode == :authors || screen == :authors
          @library.authors(query:, page:, downloaded:)
        elsif mode == :content && !query.empty?
          @library.search(query, **filters, page:, downloaded:, order:, pool_size:)
        else
          @library.browse(query:, **filters, page:, downloaded:)
        end
      end
      @network_worker.submit(work) do |result, error|
        next unless @request_number == request_number && @screen == screen

        @busy = false
        if error
          @error = error_message(error)
        else
          @result, @source = result, result.source
        end
        refresh_window
      end
    end

    def result_key(result = @result) = %w[pages authors books].find { |key| result.data.key?(key) }

    def next_result_page = following_page(@result.data)

    def source_label
      return @result ? "المحفوظ على جهازك · جارٍ التحديث…" : "جارٍ البحث…" if @busy

      local = @mode == :content && !@query.strip.empty? ? "البحث في الكتب المحمّلة · دون اتصال" : "دون اتصال · الفهرس المحفوظ"
      { online: "متصل بالجامع", offline: local, local: local,
        downloaded: "في كتبك المحمّلة فقط", cached: "الفهرس المحفوظ على جهازك" }.fetch(@source, "الجامع لسطح المكتب")
    end

    def queue_download(book)
      return unless @download_queue.enqueue(book)

      resolve_download_failure(book.fetch("id"))
      refresh_download_state
    end

    def refresh_download_state
      downloaded = @store.downloaded_ids
      @catalog_refresh_pending = true if @screen == :saved && @downloaded_ids != downloaded
      @downloaded_ids = downloaded
      @download_states = @store.download_state_counts
      update_activity
      if @screen == :reader
        @reader_availability.text = availability_label(@reader.fetch(:book))
        update_export_download if @dialog&.dig(:type) == :export
      elsif dialog_active? || @notification_focus
        @redraw_pending = true
      else
        refresh_window
      end
    end

    def connection_bar
      @connection_bar = stack(left: 0, top: height - STATUS_HEIGHT, width: width, height: STATUS_HEIGHT) do
        background surface
        separator(width: 1.0)
        row(left: (width - @chrome_width) / 2, top: 2, width: @chrome_width, height: STATUS_HEIGHT - 4) do
          @connection_text = para connection_message, width: -484, size: 13, stroke: muted, wrap: "trim", live: "polite"
          @reconnect_button = action("إعادة الاتصال", width: 126, height: 28, size: 13, variant: :ghost,
            hidden: !%i[offline unavailable].include?(@connection)) { refresh_connection }
          row(width: 330, height: 28) { draw_activity }
          icon_button("sliders-horizontal", "إعدادات الحركة", width: 28, height: 28) { open_dialog(:motion_settings) }
        end
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
      when Errno::ENOSPC then "لا توجد مساحة كافية لحفظ الملف."
      else "تعذّر إكمال العملية. أعد المحاولة."
      end
    end
  end
end
