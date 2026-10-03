# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class DownloaderTest < StoreTestCase
  class API
    attr_accessor :fail_after_first_batch, :data, :content, :batch_size
    attr_reader :starts

    def book(_id) = data

    def each_page_batch(_id, start: 1)
      (@starts ||= []) << start
      content.each_slice(batch_size || 1).drop(start - 1).each do |batch|
        yield batch
        raise Aljam3::ConnectionError, "Disconnected" if fail_after_first_batch
      end
    end
  end

  class Transport
    attr_reader :calls
    def initialize = @calls = 0

    def download(_url, destination, check:, resume:)
      check.call
      @calls += 1
      File.binwrite(destination, "%PDF-1.7\nexample")
      yield 16, 16
    end
  end

  def setup
    super
    @api = API.new
    @api.data, @api.content = book, pages
    @http = Transport.new
    @downloader = Aljam3::Downloader.new(api: @api, store: @store, directory: File.join(@directory, "books"), http: @http)
  end

  def test_download_publishes_pdf_and_searchable_pages_together
    progress = []
    @downloader.call(1) do |fraction, _message|
      progress << fraction
      refute @store.downloaded?(1)
      assert_empty @store.search("العلم").fetch("pages")
    end
    assert @store.downloaded?(1)
    assert File.file?(@downloader.pdf_path(1, 10))
    assert_equal 2, @store.search("العلم").fetch("pages").length
    assert progress.all? { |fraction| fraction.between?(0, 1) }
  end

  def test_disconnect_retains_partial_state_and_retry_does_not_download_the_pdf_again
    @api.fail_after_first_batch = true
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    refute @store.downloaded?(1)
    assert_equal 1, @store.files(1).length
    assert_equal 1, @store.page_count(10)
    assert_empty @store.search("العلم").fetch("pages")
    @api.fail_after_first_batch = false
    @downloader.call(1)
    assert @store.downloaded?(1)
    assert_equal 1, @http.calls
    assert_equal 2, @store.page_count(10)
  end

  def test_wrong_page_count_does_not_publish_download
    @api.content = [pages.first]
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    refute @store.downloaded?(1)
    refute File.exist?(@downloader.pdf_path(1, 10))
  end

  def test_resume_skips_completed_text_batches
    @api.batch_size = 500
    @api.data["files"].first["pages_count"] = 501
    @api.content = 501.times.map { |i| { "id" => 100 + i, "number" => i + 1, "content" => "العلم" } }
    @api.fail_after_first_batch = true
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    assert_equal 500, @store.page_count(10)
    @api.fail_after_first_batch = false
    @downloader.call(1)
    assert_equal [1, 2], @api.starts
    assert_equal 501, @store.page_count(10)
    assert_equal 1, @http.calls
  end

  def test_recovers_a_crash_after_renaming_the_completed_directory
    @downloader.call(1)
    @store.instance_variable_get(:@db).execute("UPDATE books SET downloaded_at = NULL WHERE id = 1")
    @downloader.call(1)
    assert @store.downloaded?(1)
    assert_equal 1, @http.calls
  end

  def test_cancelling_cleans_up_a_renamed_but_uncommitted_directory
    @downloader.call(1)
    @store.instance_variable_get(:@db).execute("UPDATE books SET downloaded_at = NULL WHERE id = 1")
    @downloader.cancel(1)
    assert_equal 0, @downloader.disk_usage(1)
    assert_empty @store.files(1)
  end

  def test_repeated_download_preserves_existing_book
    @downloader.call(1)
    @api.fail_after_first_batch = true
    assert_equal 1, @downloader.call(1).fetch("id")
    assert @store.downloaded?(1)
    assert_equal 2, @store.search("العلم").fetch("pages").length
  end

  def test_repairs_legacy_sizes_once_in_bounded_batches_without_network_access
    install_book(1)
    install_book(2)
    extra = book(1).fetch("files").first.merge("id" => 11)
    data = book(1).merge("files" => [book(1).fetch("files").first, extra])
    @store.prepare_download(data, resume: true)
    @store.complete_download(1)
    { [1, 10] => 120, [1, 11] => 230, [2, 20] => 450 }.each do |(id, file), size|
      path = @downloader.pdf_path(id, file)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, "x" * size)
    end

    assert_nil @store.download_bytes
    assert_equal 1, @downloader.repair_download_sizes(limit: 1)
    assert_equal 350, @store.download(1).fetch(:bytes)
    assert_nil @store.download(2).fetch(:bytes)
    assert_equal 2, @downloader.repair_download_sizes(after: 1, limit: 1)
    assert_equal 800, @store.download_bytes
    assert_nil @downloader.repair_download_sizes
    assert_equal 0, @http.calls
    @store.close
    @store = Aljam3::Store.new(File.join(@directory, "library.sqlite3"))
    assert_equal 800, @store.download_bytes
    assert_empty @store.downloads_without_size
  end

  def test_size_repair_does_not_publish_partial_or_missing_pdfs
    install_book(1)
    install_book(2)
    FileUtils.mkdir_p(File.dirname(@downloader.pdf_path(2, 20)))
    File.binwrite(@downloader.pdf_path(2, 20), "")
    assert_equal 2, @downloader.repair_download_sizes
    assert_nil @store.download_bytes
    assert_nil @store.download(1).fetch(:bytes)
    assert_nil @store.download(2).fetch(:bytes)
    assert_equal 0, @http.calls
  end

  def test_size_repair_cannot_overwrite_a_removed_or_replaced_download
    install_book
    stamp = @store.downloads_without_size.first.fetch("downloaded_at")
    @store.discard_download(1)
    @store.save_download_size(1, downloaded_at: stamp, bytes: 100)
    refute @store.downloaded?(1)
    install_book
    @store.save_download_size(1, downloaded_at: stamp, bytes: 100)
    assert_nil @store.download(1).fetch(:bytes)
    @store.complete_download(1, bytes: 500)
    @store.save_download_size(1, downloaded_at: stamp, bytes: 100)
    assert_equal 500, @store.download(1).fetch(:bytes)
  end

  def test_queue_repairs_legacy_metadata_in_the_background
    @downloader.call(1)
    @store.instance_variable_get(:@db).execute("UPDATE books SET download_bytes = NULL WHERE id = 1")
    queue = Aljam3::Downloads.new(store: @store, downloader: @downloader)
    Timeout.timeout(3) do
      until @store.download(1).fetch(:bytes)
        queue.tick
        sleep 0.001
      end
    end
    assert_equal File.size(@downloader.pdf_path(1, 10)), @store.download_bytes
    assert_equal 1, @http.calls
  ensure
    queue&.close
  end

  def test_cancel_discards_partial_data_and_remove_preserves_reading_history_and_bookmarks
    @api.fail_after_first_batch = true
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    @downloader.cancel(1)
    assert_empty @store.files(1)
    assert_equal 0, @downloader.disk_usage(1)
    @api.fail_after_first_batch = false
    @downloader.call(1)
    @store.save_reading(1, file_id: 10, number: 2)
    @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "العلم نور")
    @downloader.remove(1)
    refute @store.downloaded?(1)
    assert_empty @store.search("العلم").fetch("pages")
    assert_equal 0, @downloader.disk_usage(1)
    assert_equal 2, @store.recent_books.first.fetch("number")
    assert_equal 1, @store.bookmarks(1).length
  end
end
