# frozen_string_literal: true

require "json"
require "fileutils"
require "find"
require "digest"
require "securerandom"
require "tempfile"
require "tmpdir"
require_relative "instance"
require_relative "store"

module Aljam3
  # Configuration and updates stay on the system drive; only library data moves.
  class Storage
    CONFIG = "library-location.json"
    MARKER = ".aljam3-library.json"
    CONTENTS = %w[library.sqlite3 library.sqlite3-wal library.sqlite3-shm books renders].freeze
    class Error < StandardError; end
    class Unavailable < Error; end
    class Cancelled < Error; end

    attr_reader :app_directory

    def initialize(app_directory: Aljam3.data_directory)
      @app_directory = File.expand_path(app_directory)
      @location = if File.exist?(config_path)
        value = JSON.parse(File.read(config_path))
        raise Error, "تعذّر قراءة إعدادات موقع المكتبة." unless value.is_a?(Hash) &&
          value["path"].is_a?(String) && !value["path"].empty? && value["id"].is_a?(String) && !value["id"].empty?
        value
      end
    rescue JSON::ParserError, SystemCallError => error
      raise Error, "تعذّر قراءة إعدادات موقع المكتبة: #{error.message}"
    end

    def directory = @location ? @location.fetch("path") : @app_directory
    def selected? = !!@location

    def available?
      return File.directory?(@app_directory) unless @location

      File.directory?(directory) && library_matches?(directory)
    end

    def resolve!
      raise Unavailable, "لم يتم العثور على مجلد المكتبة المحدد." unless available?

      directory
    end

    # Used only for reconnecting the same library after a drive letter/path changes.
    def locate(path)
      path = File.realpath(path)
      raise Error, "هذا المجلد لا يحتوي على مكتبتك. اختر مجلد المكتبة الأصلي." unless @location && library_matches?(path)

      lock = Instance.acquire(path, create: false)
      raise Error, "هذه المكتبة مفتوحة في نافذة أخرى. أغلقها ثم حاول مجددًا." unless lock

      begin
        verify_database(path)
        select(path, @location.fetch("id"))
        lock
      rescue Exception
        lock.close
        raise
      end
    end

    def bytes
      CONTENTS.sum do |name|
        path = File.join(directory, name)
        next 0 unless File.exist?(path)

        total = 0
        Find.find(path) do |entry|
          stat = File.lstat(entry)
          Find.prune if stat.symlink?
          total += stat.size if stat.file?
        rescue Errno::ENOENT
          # Cache files and finished downloads can change during this estimate.
        end
        total
      end
    end

    def prepare(destination, app_lock: nil)
      Transfer.new(self, destination, app_lock:)
    end

    def select(path, id)
      location = { "path" => path, "id" => id }
      atomic_json(config_path, location)
      @location = location
    end

    def atomic_json(path, value)
      Tempfile.create([".aljam3-", ".tmp"], File.dirname(path)) do |file|
        file.write(JSON.generate(value))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      end
      sync_directory(File.dirname(path))
    end

    def sync_directory(path)
      File.open(path, File::RDONLY) { |file| file.fsync }
    rescue SystemCallError => error
      # Windows does not expose fsync on a directory handle.
      warn "Library directory sync: #{error.message}" unless [Errno::EINVAL, Errno::EACCES, Errno::EISDIR, Errno::ENOTSUP].any? { |type| error.is_a?(type) }
    end

    def verify_database(path)
      store = Store.new(File.join(path, "library.sqlite3"), background: false, create: false)
      store.check_integrity!
    ensure
      store&.close
    end

    private

    def config_path = File.join(@app_directory, CONFIG)

    def library_matches?(path)
      File.file?(File.join(path, "library.sqlite3")) &&
        JSON.parse(File.read(File.join(path, MARKER))) == { "id" => @location.fetch("id") }
    rescue JSON::ParserError, SystemCallError
      false
    end

    class Transfer
      attr_reader :destination, :lock

      def initialize(storage, destination, app_lock: nil)
        @storage, @source = storage, File.realpath(storage.resolve!)
        @destination = File.realpath(destination)
        # realpath also catches aliases/symlinks, and case aliases on Windows/macOS.
        if File.identical?(@source, @destination) || within?(@destination, @source) || within?(@source, @destination)
          raise Error, "اختر مجلدًا آخر خارج مجلد المكتبة الحالي."
        end
        validate_destination!
        shared_lock = app_lock if File.identical?(@destination, storage.app_directory)
        @owns_lock = !shared_lock
        @lock = shared_lock || Instance.acquire(@destination, create: false)
        raise Error, "المجلد مستخدم في نافذة أخرى. اختر مجلدًا آخر." unless @lock

        validate_destination!
        @installed = []
        @cancelled = @committed = false
      rescue Exception
        release
        raise
      end

      def cancel = @cancelled = true
      def committed? = @committed
      def release = (@lock&.close if @owns_lock)

      # The caller must close every database connection/download/reader first.
      # The source stays intact until the app has reopened the committed copy.
      def run
        @stage = Dir.mktmpdir(".aljam3-moving-", @destination)
        entries = entries_to_copy
        total = entries.sum { |_relative, stat| stat.file? ? stat.size : 0 } * 2
        done = 0
        report = ->(bytes) { done += bytes; yield(total.zero? ? 0 : done.fdiv(total)) if block_given? }
        entries.each do |relative, stat|
          check!
          target = File.join(@stage, relative)
          if stat.directory?
            FileUtils.mkdir_p(target)
          else
            copy_file(File.join(@source, relative), target, stat, report)
          end
        end
        entries.reverse_each { |relative, stat| @storage.sync_directory(File.join(@stage, relative)) if stat.directory? }
        @storage.verify_database(@stage)
        id = SecureRandom.uuid
        @storage.atomic_json(File.join(@stage, MARKER), { "id" => id })
        check!
        # A close/cancel can interrupt copying, never the short commit operation.
        Thread.handle_interrupt(Object => :never) do
          CONTENTS.each do |name|
            next unless File.exist?(File.join(@stage, name))

            File.rename(File.join(@stage, name), File.join(@destination, name))
            @installed << name
          end
          File.rename(File.join(@stage, MARKER), File.join(@destination, MARKER))
          @installed << MARKER
          @storage.sync_directory(@destination)
          @storage.select(@destination, id)
          @committed = true
        end
        @destination
      ensure
        FileUtils.remove_entry(@stage) if @stage && File.directory?(@stage)
        unless @committed
          @installed&.each { |name| FileUtils.rm_rf(File.join(@destination, name)) }
          release
        end
      end

      def cleanup_source
        raise Error, "لم يكتمل نقل المكتبة." unless @committed

        # The source lock remains held until after this call.
        (CONTENTS + [MARKER]).each { |name| FileUtils.remove_entry(File.join(@source, name)) if File.exist?(File.join(@source, name)) }
        true
      rescue SystemCallError => error
        warn "Library cleanup: #{error.message}"
        false
      end

      private

      def within?(path, parent)
        # Compare each ancestor by identity (case-insensitive filesystems included).
        ancestor = File.dirname(path)
        loop do
          return true if File.identical?(ancestor, parent)
          break if ancestor == File.dirname(ancestor)

          ancestor = File.dirname(ancestor)
        end
        false
      end

      def validate_destination!
        allowed = %w[app.lock .DS_Store desktop.ini Thumbs.db]
        allowed += [CONFIG, "updates", "analytics", "launcher.log"] if File.identical?(@destination, @storage.app_directory)
        raise Error, "اختر مجلدًا فارغًا لحفظ المكتبة؛ لن ندمجها مع ملفات أخرى." unless (Dir.children(@destination) - allowed).empty?
      end

      def entries_to_copy
        raise Unavailable, "تعذّر الوصول إلى قاعدة بيانات المكتبة." unless File.file?(File.join(@source, "library.sqlite3"))

        CONTENTS.flat_map do |name|
          root = File.join(@source, name)
          next [] unless File.exist?(root) || File.symlink?(root)

          entries = []
          Find.find(root) do |path|
            check!
            stat = File.lstat(path)
            raise Error, "تحتوي المكتبة على رابط ملفات غير مدعوم. لم تُنقل المكتبة." unless stat.file? || stat.directory?

            entries << [path.delete_prefix(@source + File::SEPARATOR), stat]
          end
          entries
        end
      end

      def copy_file(source, target, original, report)
        FileUtils.mkdir_p(File.dirname(target))
        digest = Digest::SHA256.new
        File.open(source, "rb") do |input|
          File.open(target, "wb", 0o600) do |output|
            while (chunk = input.read(1024 * 1024))
              check!
              output.write(chunk)
              digest.update(chunk)
              report.call(chunk.bytesize)
            end
            output.flush
            output.fsync
          end
          stat = input.stat
          raise Error, "تغيّرت ملفات المكتبة أثناء النقل. أعد المحاولة." unless stat.size == original.size && stat.mtime == original.mtime
        end
        copied = Digest::SHA256.new
        File.open(target, "rb") do |input|
          while (chunk = input.read(1024 * 1024))
            check!
            copied.update(chunk)
            report.call(chunk.bytesize)
          end
        end
        raise Error, "تعذّر التحقق من الملفات المنقولة. المكتبة الأصلية محفوظة." unless digest.digest == copied.digest
      end

      def check!
        raise Cancelled, "أُلغي النقل. لم يتغير موقع المكتبة." if @cancelled
      end
    end
  end
end
