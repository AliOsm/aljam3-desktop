# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < StoreTestCase
  def test_selected_author_can_be_resolved_beyond_the_first_page
    authors = 30.times.map { |index| { "id" => index + 1, "name" => "مؤلف #{index}" } }
    @store.cache_authors(authors)
    assert_equal authors.last, @store.author(30)
    assert_nil @store.author(999)
  end

  def test_arabic_search_normalizes_diacritics_tatweel_and_alef_and_preserves_original_text
    install_book
    hits = @store.search("العلم").fetch("pages")
    assert_equal [100, 101], hits.map { |hit| hit.fetch("id") }.sort
    assert_equal "آدابُ الْعِلْمِ وأَهْلِهِ في الإِسْلَامِ", @store.search("اداب الاسلام").fetch("pages").first.fetch("content")
  end

  def test_catalog_and_incomplete_downloads_are_not_searchable
    @store.cache_books([book(3)])
    install_book(1)
    install_book(2, complete: false)
    assert_equal [1], @store.search("العلم").fetch("pages").map { |hit| hit.dig("book", "id") }.uniq
    assert_equal [1], @store.catalog(downloaded: true).fetch("books").map { |item| item.fetch("id") }
    assert_equal 3, @store.catalog.fetch("pagination").fetch("count")
  end

  def test_query_punctuation_does_not_become_sql_or_fts_syntax
    install_book
    assert_empty @store.search('" * () : -').fetch("pages")
    assert_empty @store.search('x" OR 1=1 --').fetch("pages")
    assert_equal 2, @store.search('"العلم"*').fetch("pages").length
    assert_empty @store.catalog(query: "%").fetch("books")
  end

  def test_category_filter_and_pagination
    8.times { |index| install_book(index + 1, category: index < 7 ? 2 : 3) }
    first = @store.search("العلم", category: 2)
    second = @store.search("العلم", category: 2, page: 2)
    assert_equal 14, first.fetch("pagination").fetch("count")
    assert_equal 12, first.fetch("pages").length
    assert_equal 2, second.fetch("pages").length
    assert_empty(first.fetch("pages").map { |hit| hit.fetch("id") } & second.fetch("pages").map { |hit| hit.fetch("id") })
    assert_equal [8], @store.catalog(category: 3).fetch("books").map { |item| item.fetch("id") }
  end

  def test_discard_removes_the_search_index_and_retry_has_no_duplicates
    install_book
    @store.discard_download(1)
    assert_empty @store.search("العلم").fetch("pages")
    assert_nil @store.find_page(100)
    install_book
    assert_equal 2, @store.search("العلم").fetch("pages").length
  end

  def test_catalog_refresh_preserves_download_status_and_reading_position
    install_book
    @store.save_preference("reading:1", { "file_id" => 10, "number" => 2 })
    @store.cache_books([book.merge("title" => "آداب <mark>العلم</mark>").reject { |key, _| key == "files" }])
    assert @store.downloaded?(1)
    assert_equal 2, @store.preference("reading:1").fetch("number")
    assert_equal 10, @store.find_page(101).fetch("file_id")
    assert_equal 10, @store.book(1).fetch("files").first.fetch("id")
    assert_equal 1, @store.catalog(query: "اداب").fetch("books").length
  end

  def test_arabic_stemming_letter_forms_and_digit_folding
    @store.prepare_download(book)
    original = "وفي الْمَدْرَسَةِ كتابها عن الإيمان سنة ١٢٣"
    @store.add_pages(10, [{ "id" => 100, "number" => 1, "content" => original }])
    @store.complete_download(1)

    ["مدرسه", "كتاب", "ايمان", "123", "۱۲۳"].each do |query|
      hits = @store.search(query).fetch("pages")
      assert_equal [100], hits.map { |hit| hit.fetch("id") }, query
      assert_equal original, hits.first.fetch("content")
    end
  end

  def test_common_words_remain_searchable
    install_book
    assert_equal [100], @store.search("العلم في الاسلام").fetch("pages").map { |hit| hit.fetch("id") }
    assert_equal [100], @store.search("في").fetch("pages").map { |hit| hit.fetch("id") }
  end

  def test_snippet_includes_context_for_a_stemmed_match_deep_in_a_page
    @store.prepare_download(book)
    content = "تمهيد " * 100 + "هذه الْمَدْرَسَةِ مكان التعلم " + "خاتمة " * 100
    @store.add_pages(10, [{ "id" => 100, "number" => 1, "content" => content }])
    @store.complete_download(1)
    excerpt = @store.search("مدرسه").fetch("pages").first.fetch("excerpt")
    assert_includes excerpt, "هذه الْمَدْرَسَةِ مكان التعلم"
    assert_operator excerpt.length, :<, content.length
  end

  def test_version_one_library_is_reindexed_without_losing_downloads_or_reading_position
    path = File.join(@directory, "old-library.sqlite3")
    SQLite3::Database.new(path) do |db|
      db.execute_batch(File.read(File.join(__dir__, "fixtures/schema_v1.sql")))
      db.execute("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?)", [1, "آداب العلم", "اداب العلم", 2, JSON.generate(book), "2026-09-30"])
      db.execute("INSERT INTO files VALUES (?, ?, ?, ?)", [10, 1, 0, JSON.generate(book.fetch("files").first)])
      db.execute("INSERT INTO pages VALUES (?, ?, ?, ?, ?)", [100, 10, 1, "كتابها في الْمَدْرَسَةِ", "كتابها في المدرسة"])
      db.execute("INSERT INTO preferences VALUES (?, ?)", ["reading:1", JSON.generate({ "file_id" => 10, "number" => 1 })])
    end
    migrated = Aljam3::Store.new(path)
    assert migrated.downloaded?(1)
    assert_equal 1, migrated.preference("reading:1").fetch("number")
    assert_equal 1, migrated.recent_books.first.fetch("number")
    assert_equal [100], migrated.search("مدرسه كتاب").fetch("pages").map { |hit| hit.fetch("id") }
    assert_equal "كتابها في الْمَدْرَسَةِ", migrated.find_page(100).fetch("content")
    migrated.close
    migrated = Aljam3::Store.new(path)
    assert_equal 1, migrated.search("مدرسه").fetch("pages").length
    migrated.discard_download(1)
    assert_empty migrated.search("مدرسه").fetch("pages")
  ensure
    migrated&.close
  end

  def test_history_and_bookmarks_survive_reopen_and_removing_downloads
    install_book
    install_book(2)
    @store.save_reading(1, file_id: 10, number: 1)
    @store.save_reading(2, file_id: 20, number: 1)
    @store.save_reading(1, file_id: 10, number: 2)
    assert @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "العلم نور")
    @store.discard_download(1)
    @store.close
    @store = Aljam3::Store.new(File.join(@directory, "library.sqlite3"))
    assert_equal [1, 2], @store.recent_books.map { |entry| entry.fetch("book_id") }
    assert_equal 2, @store.recent_books(limit: 1).first.fetch("number")
    assert_equal "العلم نور", @store.bookmarks(1).first.fetch("excerpt")
    refute @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "")
    assert_empty @store.bookmarks(1)
  end

  def test_bookmark_toggle_cannot_upgrade_a_snapshot_invalidated_by_a_download
    @store.cache_books([book])
    database = @store.instance_variable_get(:@db)
    writer = SQLite3::Database.new(File.join(@directory, "library.sqlite3"))
    read = database.method(:get_first_value)
    competed = false
    database.define_singleton_method(:get_first_value) do |sql, *args|
      result = read.call(sql, *args)
      if sql.include?("SELECT 1 FROM bookmarks")
        competed = true
        begin
          writer.execute("UPDATE books SET download_bytes = 123 WHERE id = 1")
        rescue SQLite3::BusyException
          # Wait for the reserved bookmark transaction, as the indexer does.
        end
      end
      result
    end
    assert @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "العلم")
    assert competed
    writer.execute("UPDATE books SET download_bytes = 123 WHERE id = 1")
    assert_equal 1, @store.bookmarks(1).length
    refute @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "")
    assert_empty @store.bookmarks(1)
  ensure
    database.singleton_class.remove_method(:get_first_value) if read
    writer&.close
  end

  def test_resuming_a_partially_indexed_batch_does_not_duplicate_pages
    @store.prepare_download(book)
    @store.add_pages(10, pages.first(1))
    @store.prepare_download(book, resume: true)
    @store.add_pages(10, pages)
    assert_equal 2, @store.page_count(10)
    @store.complete_download(1)
    assert_equal [100, 101], @store.search("العلم").fetch("pages").map { |hit| hit.fetch("id") }.sort
  end
end
