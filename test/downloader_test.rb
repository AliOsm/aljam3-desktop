# frozen_string_literal: true

require_relative "test_helper"

class DownloaderTest < StoreTestCase
  class API
    attr_accessor :fail_after_first_batch, :data, :content

    def book(_id) = data

    def each_page_batch(_id)
      yield [content.first]
      raise Aljam3::ConnectionError, "Disconnected" if fail_after_first_batch

      yield content.drop(1)
    end
  end

  class Transport
    def download(_url, destination)
      File.binwrite(destination, "%PDF-1.7\nexample")
      yield 16, 16
    end
  end

  def setup
    super
    @api = API.new
    @api.data, @api.content = book, pages
    @downloader = Aljam3::Downloader.new(api: @api, store: @store, directory: File.join(@directory, "books"), http: Transport.new)
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

  def test_disconnect_cleans_partial_state_and_retry_succeeds
    @api.fail_after_first_batch = true
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    refute @store.downloaded?(1)
    assert_empty @store.files(1)
    assert_empty @store.search("العلم").fetch("pages")
    assert_empty Dir.children(File.join(@directory, "books"))
    @api.fail_after_first_batch = false
    @downloader.call(1)
    assert @store.downloaded?(1)
  end

  def test_wrong_page_count_does_not_publish_download
    @api.content = [pages.first]
    assert_raises(Aljam3::ConnectionError) { @downloader.call(1) }
    refute @store.downloaded?(1)
    refute File.exist?(@downloader.pdf_path(1, 10))
  end

  def test_repeated_download_preserves_existing_book
    @downloader.call(1)
    @api.fail_after_first_batch = true
    assert_equal 1, @downloader.call(1).fetch("id")
    assert @store.downloaded?(1)
    assert_equal 2, @store.search("العلم").fetch("pages").length
  end
end
