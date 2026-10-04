# frozen_string_literal: true

require "fileutils"

module Aljam3
  # One UI owns a library's download queue and partial files. The OS releases
  # the lock even after a crash; leave the lock file in place to avoid races.
  class Instance
    def self.acquire(directory)
      FileUtils.mkdir_p(directory)
      file = File.open(File.join(directory, "app.lock"), File::RDWR | File::CREAT, 0o600)
      return new(file) if file.flock(File::LOCK_EX | File::LOCK_NB)

      file.close
      nil
    end

    def initialize(file) = @file = file
    def close
      @file.close unless @file.closed?
    end
    private_class_method :new
  end
end
