# frozen_string_literal: true

Encoding.default_external = Encoding::UTF_8
require_relative "../store"

begin
  store = Aljam3::Store.new(ARGV.fetch(0), background: false)
  $stdout.sync = true
  $stdin.each_line do |line|
    request = JSON.parse(line)
    method = request.fetch("method")
    raise ArgumentError, "Unknown library operation" unless Aljam3::Store::Worker::METHODS.include?(method)

    begin
      result = store.public_send(method, *request.fetch("arguments"), **request.fetch("options").transform_keys(&:to_sym))
      puts JSON.generate(result:)
    rescue StandardError => error
      puts JSON.generate(error: error.message)
    end
  end
ensure
  store&.close
end
