# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/pdf"

class PDFEncodingTest < Minitest::Test
  def test_direct_png_preserves_every_channel_including_alpha_and_row_boundaries
    Dir.mktmpdir("aljam3-png-") do |directory|
      pdf = Aljam3::PDF.new(cache: directory)
      [[1, 1], [3, 29], [760, 1100]].each do |width, height|
        pixels = Random.new(7).bytes(width * height * 4)
        path = File.join(directory, "page.png")
        pdf.send(:write_png, path, width, height, pixels)
        actual = ChunkyPNG::Image.from_file(path)
        assert_equal [width, height], [actual.width, actual.height]
        assert_equal pixels, actual.to_rgba_stream
      end
    end
  end
end
