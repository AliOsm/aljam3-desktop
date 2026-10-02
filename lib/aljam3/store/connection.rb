# frozen_string_literal: true

module Aljam3
  class Store
    class Connection
      def initialize(path, extension:, readonly: false)
        @db = SQLite3::Database.new(path, results_as_hash: true, extensions: [extension], readonly:)
        @db.busy_handler_timeout = 5_000
        @db.execute_batch("PRAGMA foreign_keys = ON; PRAGMA cache_size = -8192;")
        @lock = Mutex.new
      end

      def call
        @lock.synchronize { yield @db }
      end

      def close = call(&:close)
    end
  end
end
