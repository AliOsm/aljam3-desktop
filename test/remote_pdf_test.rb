# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/pdf"
require_relative "support/range_pdf"

class RemotePDFTest < Minitest::Test
  class HTTP
    attr_reader :calls
    attr_accessor :error, :edition, :redirect

    def initialize
      @calls, @edition = [], 1
    end

    def read_range(url, offset:, length:, validator: nil)
      @calls << [url, offset, length, validator]
      raise @error if @error

      if validator && validator != @edition.to_s
        raise Aljam3::RemoteFileChangedError
      end
      bytes = (offset / Aljam3::RemotePDF::BLOCK_SIZE % 256).chr.b * length
      Aljam3::HTTP::Range.new(bytes, 100_000_000, @edition.to_s, @redirect || url)
    end
  end

  def test_seeking_crosses_blocks_and_reuses_cached_bytes
    http = HTTP.new
    source = Aljam3::RemotePDF.new("https://example.org/book.pdf", http:)
    size = Aljam3::RemotePDF::BLOCK_SIZE
    assert_empty http.calls
    assert_equal "\0\0\1\1".b, source.read(size - 2, 4)
    assert_equal 2, http.calls.size
    assert_equal "\1\1".b, source.read(size, 2)
    assert_equal 2, http.calls.size
    assert_raises(ArgumentError) { source.read(100_000_000, 1) }
  end

  def test_chunk_cache_is_bounded_and_keeps_recently_used_blocks
    http = HTTP.new
    source = Aljam3::RemotePDF.new("book.pdf", http:)
    count, size = Aljam3::RemotePDF::CACHE_BLOCKS, Aljam3::RemotePDF::BLOCK_SIZE
    count.times { |i| source.read(i * size, 1) }
    source.read(0, 1)
    source.read(count * size, 1)
    source.read(0, 1)
    assert_equal count + 1, http.calls.size
    source.read(size, 1)
    assert_equal count + 2, http.calls.size
  end

  def test_expired_cdn_url_is_resolved_again_without_discarding_valid_cached_chunks
    http = HTTP.new
    http.redirect = "https://cdn.example.org/signed.pdf"
    source = Aljam3::RemotePDF.new("https://example.org/book.pdf", http:)
    source.size
    original = http.method(:read_range)
    http.define_singleton_method(:read_range) do |url, **options|
      raise Aljam3::ResponseError, 403 if url == redirect

      original.call(url, **options)
    end
    assert_equal "\1".b, source.read(Aljam3::RemotePDF::BLOCK_SIZE, 1)
    assert_equal "https://example.org/book.pdf", http.calls.last.first
    assert_equal "1", http.calls.last.last
  end

  def test_changed_edition_discards_cached_chunks_and_can_be_retried
    http = HTTP.new
    source = Aljam3::RemotePDF.new("book.pdf", http:)
    first_key = source.cache_key
    http.edition = 2
    assert_raises(Aljam3::RemoteFileChangedError) { source.read(Aljam3::RemotePDF::BLOCK_SIZE, 1) }
    refute_equal first_key, source.cache_key
    assert_equal [0, Aljam3::RemotePDF::BLOCK_SIZE, 0], http.calls.map { |call| call[1] }
  end

  def test_first_middle_and_last_pages_render_from_ranges_and_match_local_pdf
    data = RangePDF.document
    Dir.mktmpdir do |directory|
      path = File.join(directory, "book.pdf")
      File.binwrite(path, data)
      pdf = Aljam3::PDF.new(cache: File.join(directory, "renders"))
      RangePDF.serve(data) do |url, requests|
        source = Aljam3::RemotePDF.new(url)
        [1, 12, 24].each do |page|
          remote = pdf.render(source, page:, width: 240)
          local = pdf.render(path, page:, width: 240)
          assert_equal File.binread(local.path), File.binread(remote.path)
        end
        assert_operator requests.sum(&:last), :<, data.bytesize * 0.75
        before = requests.size
        pdf.render(source, page: 12, width: 240)
        assert_equal before, requests.size
        # A different zoom renders again from the same cached byte ranges.
        pdf.render(source, page: 12, width: 300)
        assert_equal before, requests.size
      end
    end
  end

  def test_callback_errors_and_cancelled_page_changes_do_not_escape_into_native_code
    data = RangePDF.document
    Dir.mktmpdir do |directory|
      RangePDF.serve(data) do |url, _requests|
        source = Aljam3::RemotePDF.new(url)
        pdf = Aljam3::PDF.new(cache: directory)
        checks = 0
        assert_raises(Aljam3::PDF::Cancelled) do
          pdf.render(source, page: 12, width: 240, check: -> { checks += 1; raise Aljam3::PDF::Cancelled if checks > 3 })
        end
        assert_empty Dir.glob(File.join(directory, "*.png"))
        source.define_singleton_method(:read) { |*| raise Aljam3::ConnectionError, "Interrupted" }
        assert_raises(Aljam3::ConnectionError) { pdf.render(source, page: 12, width: 240) }
        source.singleton_class.remove_method(:read)
        assert File.file?(pdf.render(source, page: 12, width: 240).path)
      end
    end
  end
end
