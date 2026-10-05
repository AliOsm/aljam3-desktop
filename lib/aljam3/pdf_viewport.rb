# frozen_string_literal: true

module Aljam3
  # Geometry for a continuous volume. Unknown pages use an estimate until rendered;
  # only dimensions are retained for distant pages, never their decoded images.
  class PDFViewport
    GAP = 16
    attr_reader :count, :width, :height, :zoom, :total_height

    def initialize(count:)
      @count = [count, 1].max
      @ratios = {}
    end

    def resize(width:, height:, zoom:)
      return false if [@width, @height, @zoom] == [width, height, zoom]

      @width, @height, @zoom = width, height, zoom
      layout
      true
    end

    def learn(page, width:, height:)
      ratio = height.fdiv(width)
      return false if @ratios[page] && (@ratios[page] - ratio).abs < 0.002

      @ratios[page] = ratio
      layout
      true
    end

    def ratio(page) = @ratios.fetch(page, Math.sqrt(2))

    def dimensions(page)
      ratio = self.ratio(page)
      width = [@width - 32, (@height - 32) / ratio].min * @zoom
      [width.round, (width * ratio).round]
    end

    def top(page) = @tops.fetch(page - 1)
    def page_height(page) = @heights.fetch(page - 1)
    def clamp(top) = top.clamp(0, [@total_height - @height, 0].max)

    def page_at(offset)
      (@tops.bsearch_index { |top| top > offset } || @count).clamp(1, @count)
    end

    def visible(top)
      (page_at(top)..page_at(top + @height - 1)).to_a
    end

    def nearby(top)
      pages = visible(top)
      ([pages.first - 1, 1].max..[pages.last + 1, @count].min).to_a
    end

    def active(top)
      pages = visible(top)
      fully_visible = pages.find { |page| self.top(page) >= top && self.top(page) + page_height(page) <= top + @height }
      return fully_visible if fully_visible

      pages.max_by do |page|
        [self.top(page) + page_height(page), top + @height].min - [self.top(page), top].max
      end
    end

    # Retain the point at the viewport centre when zooming or learning dimensions.
    def anchor(top, at: 0.5)
      point = top + @height * at
      page = page_at(point)
      [page, (point - self.top(page)).fdiv(page_height(page)), at]
    end

    def position(anchor)
      page, fraction, at = anchor
      clamp(top(page) + page_height(page) * fraction - @height * at)
    end

    private

    def layout
      @tops, @heights = [], []
      offset = 0
      @count.times do |index|
        @tops << offset
        height = dimensions(index + 1).last + GAP
        @heights << height
        offset += height
      end
      # The final page can always be aligned at the top, even if it is short.
      @total_height = @tops.last + [@heights.last, @height].max
    end
  end
end
