# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/aljam3"

module Fixtures
  def book(id = 1, category: 2)
    {
      "id" => id, "title" => "آداب العلم #{id}", "author" => { "id" => 4, "name" => "النووي" },
      "category" => { "id" => category, "name" => "علوم" }, "library" => { "id" => 3, "name" => "الوقفية" },
      "pages_count" => 2, "files_count" => 1,
      "files" => [{ "id" => id * 10, "name" => "المجلد الأول", "pages_count" => 2, "urls" => { "pdf" => "https://example.org/#{id}.pdf" } }]
    }
  end

  def pages(id = 1)
    [
      { "id" => id * 100, "number" => 1, "content" => "آدابُ الْعِلْمِ وأَهْلِهِ في الإِسْلَامِ" },
      { "id" => id * 100 + 1, "number" => 2, "content" => "العِـلْـمُ نورٌ" }
    ]
  end

  def install_book(id = 1, category: 2, complete: true)
    @store.prepare_download(book(id, category:))
    @store.add_pages(id * 10, pages(id))
    @store.complete_download(id) if complete
  end
end

class StoreTestCase < Minitest::Test
  include Fixtures

  def setup
    @directory = Dir.mktmpdir("aljam3-test")
    @store = Aljam3::Store.new(File.join(@directory, "library.sqlite3"))
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@directory)
  end
end
