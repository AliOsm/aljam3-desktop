# frozen_string_literal: true

require_relative "http"

module Aljam3
  # A seekable HTTP source for PDFium. Reading never starts a background download.
  class RemotePDF
    BLOCK_SIZE = 64 * 1024
    CACHE_BLOCKS = 128 # At most 8 MiB per open volume, held only for this session.
    FETCH_BLOCKS = 8 # Coalesce only adjacent ranges the parser actually requested.

    def initialize(url, http: HTTP.new)
      @url = @resolved_url = url
      @http, @blocks = http, {}
      @unversioned_key = Random.bytes(16).unpack1("H*")
    end

    def size
      block(0) unless @size
      @size
    end

    def cache_key = [@url, size, @validator || @unversioned_key].join(":")

    def read(offset, length, check: -> {})
      raise ArgumentError, "Read outside PDF." unless offset >= 0 && length >= 0 && offset + length <= size

      bytes = +"".b
      while bytes.bytesize < length
        check.call
        index, start = (offset + bytes.bytesize).divmod(BLOCK_SIZE)
        last = (offset + length - 1) / BLOCK_SIZE
        bytes << block(index, last:, check:).byteslice(start, [length - bytes.bytesize, BLOCK_SIZE - start].min)
      end
      bytes
    end

    def prefetch_index(offsets, check:)
      check.call
      indices = offsets.select { |offset| offset.positive? && offset < size }
        .map { |offset| offset / BLOCK_SIZE }.uniq.reject { |index| @blocks.key?(index) }.take(CACHE_BLOCKS)
      return if indices.size < 4 || !@http.respond_to?(:read_ranges)

      ranges = indices.map { |index| [index * BLOCK_SIZE, BLOCK_SIZE] }
      responses = @http.read_ranges(@resolved_url, ranges:, validator: @validator, check:)
      raise RemoteFileChangedError, "The PDF changed. Please retry." unless responses.all? { |response| response.size == @size }

      check.call
      indices.zip(responses).each do |index, response|
        @blocks[index] = response.bytes
        @blocks.shift if @blocks.size > CACHE_BLOCKS
      end
    rescue RemoteFileChangedError
      @blocks.clear
      @size = @validator = nil
      @resolved_url = @url
      raise
    rescue ResponseError => error
      raise unless [401, 403].include?(error.status) && @resolved_url != @url

      @resolved_url = @url
      retry
    end

    private

    def block(index, last: index, check: -> {})
      unless @blocks.key?(index)
        count = 1
        count += 1 while count < FETCH_BLOCKS && index + count <= last && !@blocks.key?(index + count)
        fetch(index, count:, check:)
      end
      value = @blocks.delete(index)
      @blocks[index] = value
      @blocks.shift if @blocks.size > CACHE_BLOCKS
      value
    end

    def fetch(index, count:, check:)
      check.call
      response = @http.read_range(@resolved_url, offset: index * BLOCK_SIZE, length: count * BLOCK_SIZE, validator: @validator, check:)
      raise RemoteFileChangedError, "The PDF changed. Please retry." if @size && @size != response.size

      @size, @validator, @resolved_url = response.size, response.validator, response.url
      check.call
      count.times do |part|
        bytes = response.bytes.byteslice(part * BLOCK_SIZE, BLOCK_SIZE)
        break if !bytes || bytes.empty?

        @blocks[index + part] = bytes
        @blocks.shift if @blocks.size > CACHE_BLOCKS
      end
    rescue RemoteFileChangedError
      @blocks.clear
      @size = @validator = nil
      @resolved_url = @url
      raise
    rescue ResponseError => error
      # CDN links can expire while a book remains open. Resolve the original URL again.
      raise unless [401, 403].include?(error.status) && @resolved_url != @url

      @resolved_url = @url
      retry
    end
  end
end
