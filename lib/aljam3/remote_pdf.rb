# frozen_string_literal: true

require_relative "http"

module Aljam3
  # A seekable HTTP source for PDFium. Reading never starts a background download.
  class RemotePDF
    BLOCK_SIZE = 64 * 1024
    CACHE_BLOCKS = 128 # At most 8 MiB per open volume, held only for this session.

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
        bytes << block(index).byteslice(start, [length - bytes.bytesize, BLOCK_SIZE - start].min)
      end
      bytes
    end

    private

    def block(index)
      value = @blocks.delete(index) || fetch(index)
      @blocks[index] = value
      @blocks.shift if @blocks.size > CACHE_BLOCKS
      value
    end

    def fetch(index)
      response = @http.read_range(@resolved_url, offset: index * BLOCK_SIZE, length: BLOCK_SIZE, validator: @validator)
      raise RemoteFileChangedError, "The PDF changed. Please retry." if @size && @size != response.size

      @size, @validator, @resolved_url = response.size, response.validator, response.url
      response.bytes
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
