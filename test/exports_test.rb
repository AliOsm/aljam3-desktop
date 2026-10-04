# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/exports"

class ExportsTest < StoreTestCase
  class View
    include Aljam3::UI::Exports
    attr_accessor :answer
    attr_reader :options

    def initialize(store, book)
      @store, @reader = store, { book: }
    end

    def ask_save_file(**options)
      @options = options
      @answer
    end
  end

  def test_every_format_has_an_arabic_suggestion_and_native_type_constraint
    view = View.new(@store, book)
    %w[pdf txt docx png].each do |format|
      view.answer = File.join(@directory, "كتاب.#{format.upcase}")
      assert_equal view.answer, view.export_destination(format)
      assert_equal "آداب العلم 1.#{format}", view.options.fetch(:filename)
      assert_equal [format], view.options.fetch(:extensions)
      assert view.options.fetch(:expanded)
      assert_equal @directory, @store.preference("export_directory")
    end
    assert_equal @directory, view.options.fetch(:directory)
  end

  def test_cancellation_does_not_change_the_remembered_directory
    view = View.new(@store, book)
    @store.save_preference("export_directory", @directory)
    [nil, ""].each do |answer|
      view.answer = answer
      assert_nil view.export_destination("pdf")
      assert_equal @directory, @store.preference("export_directory")
    end
  end

  def test_safe_names_keep_arabic_and_identify_volume_and_page
    assert_equal "كتاب - الثاني - صفحة 4.png", Aljam3::ExportName.build("كتاب", "png", part: "الثاني", page: 4)
    assert_equal "كتاب.pdf", Aljam3::ExportName.build("كتاب.PDF", "pdf")
    assert_equal "كتاب جديد.txt", Aljam3::ExportName.build("كتاب:/جديد? ", "txt")
    assert_equal "الجامع.docx", Aljam3::ExportName.build("...", "docx")
    name = Aljam3::ExportName.build("آدابُ العلم " * 100, "docx")
    assert name.valid_encoding?
    assert_operator name.bytesize, :<=, 255
    File.write(File.join(@directory, name), "export")
    assert_equal ".docx", File.extname(name)
  end
end
