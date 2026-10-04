# frozen_string_literal: true

module Aljam3
  class NavigationHistory
    LIMIT = 60

    def initialize
      @back, @forward = [], []
    end

    def visit(location)
      @back << location unless @back.last == location
      @back.shift while @back.length > LIMIT
      @forward.clear
    end

    def back? = !@back.empty?

    def move(direction, current)
      source, destination = direction == :back ? [@back, @forward] : [@forward, @back]
      return if source.empty?

      destination << current
      source.pop
    end
  end
end
