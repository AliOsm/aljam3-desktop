# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/storage"
require "timeout"

class StorageTest < Minitest::Test
  include Fixtures

  def setup
    @scratch = Dir.mktmpdir("aljam3-storage-")
    @directory = File.join(@scratch, "app")
    @destination = File.join(@scratch, "مكتبتي الجديدة")
    FileUtils.mkdir_p([@directory, @destination])
    @store = Aljam3::Store.new(File.join(@directory, "library.sqlite3"))
    install_book
    @store.save_reading(1, file_id: 10, number: 2)
    @store.toggle_bookmark(1, file_id: 10, number: 2, excerpt: "العلم نور")
    @store.save_preference("theme", "dark")
    @store.cache_books([book(2), book(3), book(4)])
    @store.save_download(2, { book: book(2), status: :paused, fraction: 0.5, message: "paused", bytes: 7 })
    @store.queue_category_download({ "id" => 2, "name" => "علوم" }, [3, 4])
    @store.close
    @store = nil
    FileUtils.mkdir_p([File.join(@directory, "books/1"), File.join(@directory, "books/.partial/2"), File.join(@directory, "renders"), File.join(@directory, "updates")])
    File.binwrite(File.join(@directory, "books/1/10.pdf"), "%PDF-1.7\n" + "book" * 300_000)
    File.binwrite(File.join(@directory, "books/.partial/2/20.pdf"), "partial")
    File.write(File.join(@directory, "renders/page.png"), "cached image")
    File.write(File.join(@directory, "updates/package"), "update")
    @storage = Aljam3::Storage.new(app_directory: @directory)
    @instance = Aljam3::Instance.acquire(@directory)
  end

  def teardown
    @store&.close
    @transfer&.lock&.close
    @instance&.close
    FileUtils.remove_entry(@scratch)
  end

  def transfer(destination = @destination)
    @transfer = @storage.prepare(destination)
  end

  def reopened = Aljam3::Storage.new(app_directory: @directory)

  def assert_original_intact
    assert_equal @directory, reopened.resolve!
    assert File.file?(File.join(@directory, "library.sqlite3"))
    assert_equal "partial", File.binread(File.join(@directory, "books/.partial/2/20.pdf"))
    assert_equal ["app.lock"], Dir.children(@destination)
  end

  def test_verified_move_preserves_offline_search_reading_bookmarks_queue_and_partial_files
    original = File.binread(File.join(@directory, "books/1/10.pdf"))
    fractions = []
    transfer.run { |fraction| fractions << fraction }
    assert @transfer.committed?
    assert_equal @destination, reopened.resolve!
    assert File.file?(File.join(@directory, "library.sqlite3")), "keep original until new library opens"
    assert_nil Aljam3::Instance.acquire(@destination), "destination stays locked throughout reopening"
    @store = Aljam3::Store.new(File.join(@destination, "library.sqlite3"))
    assert_equal Set[1], @store.downloaded_ids
    assert_equal 2, @store.search("العلم").fetch("pages").length
    assert_equal({ "file_id" => 10, "number" => 2 }, @store.preference("reading:1"))
    assert_equal 2, @store.recent_books.first.fetch("number")
    assert_equal "العلم نور", @store.bookmarks(1).first.fetch("excerpt")
    assert_equal "dark", @store.preference("theme")
    assert_equal :paused, @store.download(2).fetch(:status)
    assert_equal [3, 4], @store.category_download_book_ids(2)
    assert_equal original, File.binread(File.join(@destination, "books/1/10.pdf"))
    assert_equal "partial", File.binread(File.join(@destination, "books/.partial/2/20.pdf"))
    assert_equal "cached image", File.read(File.join(@destination, "renders/page.png"))
    assert_equal fractions.sort, fractions
    assert_equal 1, fractions.last
    assert @transfer.cleanup_source
    refute File.exist?(File.join(@directory, "books"))
    refute File.exist?(File.join(@directory, "library.sqlite3"))
    assert_equal "update", File.read(File.join(@directory, "updates/package"))
    refute File.exist?(File.join(@destination, "updates"))
    refute Dir.children(@destination).any? { |name| name.start_with?(".aljam3-moving-") }
  end

  def test_storage_estimate_includes_database_partial_downloads_and_cache_but_not_updates
    total = Aljam3::Storage::CONTENTS.sum do |name|
      Dir.glob(File.join(@directory, name, "**/*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }.sum { |p| File.size(p) } +
        (File.file?(File.join(@directory, name)) ? File.size(File.join(@directory, name)) : 0)
    end
    assert_equal total, @storage.bytes
  end

  def test_cancel_before_copy_leaves_original_selected
    transfer.cancel
    assert_raises(Aljam3::Storage::Cancelled) { @transfer.run }
    assert_original_intact
  end

  def test_cancel_during_copy_removes_only_our_partial_copy
    transfer
    assert_raises(Aljam3::Storage::Cancelled) do
      @transfer.run { |_fraction| @transfer.cancel }
    end
    assert_original_intact
  end

  def test_disk_full_preserves_source_and_releases_destination_lock
    assert_raises(Errno::ENOSPC) { transfer.run { raise Errno::ENOSPC } }
    assert_original_intact
    lock = Aljam3::Instance.acquire(@destination)
    refute_nil lock
  ensure
    lock&.close
  end

  def test_failure_to_save_location_rolls_back_installed_files
    @storage.stub(:select, ->(*) { raise Errno::EACCES }) do
      assert_raises(Errno::EACCES) { transfer.run }
    end
    assert_original_intact
  end

  def test_closing_during_copy_preserves_original_and_releases_lock
    started = Queue.new
    gate = Queue.new
    transfer
    thread = Thread.new { @transfer.run { started << true; gate.pop } }
    Timeout.timeout(5) { started.pop }
    thread.kill.join
    assert_original_intact
    lock = Aljam3::Instance.acquire(@destination)
    refute_nil lock
  ensure
    thread&.kill&.join
    lock&.close
  end

  def test_closing_during_commit_finishes_switch_before_releasing_files
    entered, gate = Queue.new, Queue.new
    original_select = @storage.method(:select)
    @storage.define_singleton_method(:select) do |*args|
      entered << true
      gate.pop
      original_select.call(*args)
    end
    transfer
    thread = Thread.new { @transfer.run }
    Timeout.timeout(5) { entered.pop }
    thread.kill
    gate << true
    thread.join
    assert @transfer.committed?
    assert_equal @destination, reopened.resolve!
    assert File.file?(File.join(@directory, "library.sqlite3"))
    @store = Aljam3::Store.new(File.join(@destination, "library.sqlite3"))
    assert_equal Set[1], @store.downloaded_ids
  ensure
    gate << true if gate
    thread&.kill&.join
  end

  def test_source_cannot_be_deleted_before_commit
    assert_raises(Aljam3::Storage::Error) { transfer.cleanup_source }
    assert File.file?(File.join(@directory, "library.sqlite3"))
  end

  def test_corrupt_copied_database_never_becomes_active
    @storage.stub(:verify_database, ->(*) { raise "integrity failed" }) do
      assert_raises(RuntimeError) { transfer.run }
    end
    assert_original_intact
  end

  def test_altered_copy_is_detected
    changed = false
    assert_raises(Aljam3::Storage::Error) do
      transfer.run do |_fraction|
        next if changed

        candidate = Dir.glob(File.join(@destination, ".aljam3-moving-*", "library.sqlite3")).first
        next unless candidate && File.size(candidate).positive?

        File.open(candidate, "r+b") { |file| file.write("bad") }
        changed = true
      end
    end
    assert changed
    assert_original_intact
  end

  def test_nonempty_target_is_never_overwritten
    File.write(File.join(@destination, "my-file"), "keep")
    assert_raises(Aljam3::Storage::Error) { transfer }
    assert_equal ["my-file"], Dir.children(@destination)
    assert_equal "keep", File.read(File.join(@destination, "my-file"))
  end

  def test_same_nested_and_ancestor_paths_are_rejected
    nested = File.join(@directory, "inside")
    FileUtils.mkdir_p(nested)
    [@directory, nested, @scratch].each do |path|
      assert_raises(Aljam3::Storage::Error) { @storage.prepare(path) }
    end
  end

  def test_symlink_alias_to_source_is_rejected
    skip "symlinks require privileges on Windows" if Gem.win_platform?

    path = File.join(@scratch, "alias")
    File.symlink(@directory, path)
    assert_raises(Aljam3::Storage::Error) { @storage.prepare(path) }
  end

  def test_links_inside_library_do_not_copy_or_delete_external_files
    skip "symlinks require privileges on Windows" if Gem.win_platform?

    outside = File.join(@scratch, "outside.pdf")
    File.write(outside, "keep")
    File.symlink(outside, File.join(@directory, "books/linked.pdf"))
    assert_raises(Aljam3::Storage::Error) { transfer.run }
    assert_original_intact
    assert_equal "keep", File.read(outside)
  end

  def test_destination_owned_by_another_app_is_rejected
    lock = Aljam3::Instance.acquire(@destination)
    assert_raises(Aljam3::Storage::Error) { transfer }
  ensure
    lock&.close
  end

  def test_missing_drive_never_creates_an_empty_library
    transfer.run
    @transfer.lock.close
    File.rename(@destination, @destination + "-disconnected")
    refute reopened.available?
    assert_raises(Aljam3::Storage::Unavailable) { reopened.resolve! }
    refute File.exist?(@destination)
    assert_equal @destination, reopened.directory
  end

  def test_existing_empty_mount_is_also_unavailable
    transfer.run
    @transfer.lock.close
    File.rename(@destination, @destination + "-disconnected")
    FileUtils.mkdir_p(@destination)
    assert_raises(Aljam3::Storage::Unavailable) { reopened.resolve! }
    assert_empty Dir.children(@destination)
  end

  def test_reopening_never_creates_database_if_drive_disappears_after_resolution
    transfer.run
    @transfer.lock.close
    path = reopened.resolve!
    File.rename(path, path + "-gone")
    assert_raises(SQLite3::CantOpenException) { Aljam3::Store.new(File.join(path, "library.sqlite3"), create: false) }
    refute File.exist?(path)
  end

  def test_reconnect_requires_the_same_library_and_handles_changed_drive_path
    transfer.run
    @transfer.lock.close
    new_path = @destination + "-reconnected"
    File.rename(@destination, new_path)
    assert_raises(Aljam3::Storage::Error) { reopened.locate(@directory) }
    storage = reopened
    lock = storage.locate(new_path)
    assert_equal new_path, storage.resolve!
    assert_equal new_path, reopened.resolve!
    assert_nil Aljam3::Instance.acquire(new_path)
  ensure
    lock&.close
  end

  def test_library_can_move_back_to_default_without_moving_updater_files
    transfer.run
    @transfer.cleanup_source
    @transfer.lock.close
    @transfer = @storage.prepare(@directory, app_lock: @instance)
    @transfer.run
    @transfer.cleanup_source
    assert_equal @directory, reopened.resolve!
    assert_equal "update", File.read(File.join(@directory, "updates/package"))
    refute File.exist?(File.join(@destination, "books"))
  end

  def test_invalid_configuration_does_not_silently_reset_library
    File.write(File.join(@directory, Aljam3::Storage::CONFIG), "broken")
    assert_raises(Aljam3::Storage::Error) { reopened }
    assert_equal "broken", File.read(File.join(@directory, Aljam3::Storage::CONFIG))
  end
end
