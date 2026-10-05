# frozen_string_literal: true

module Aljam3
  module Formatting
    def self.number(value)
      integer, fraction = value.to_s.split(".", 2)
      grouped = integer.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')
      fraction ? "#{grouped}.#{fraction}" : grouped
    end
  end
end
