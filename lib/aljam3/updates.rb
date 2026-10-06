# frozen_string_literal: true

require "json"
require "openssl"
require "base64"
require "digest"
require "net/http"
require "fileutils"
require "uri"
require "cgi"
require_relative "version"

module Aljam3
  # Release metadata is signed as exact bytes, before any URLs are trusted.
  class Updates
    class Error < StandardError; end
    REPOSITORY = "AliOsm/aljam3-desktop"
    FEED = "https://github.com/#{REPOSITORY}/releases/latest/download/update.json"
    MAX_PACKAGE = 1_500_000_000
    INTERVAL = 86_400
    attr_reader :version, :target, :directory

    def initialize(directory:, resources: ENV["ALJAM3_BUNDLE_ROOT"], public_key: nil, transport: nil)
      @directory = File.join(directory, "updates")
      @resources = resources
      build = resources && JSON.parse(File.read(File.join(resources, "build.json")))
      @version, @target = build ? build.values_at("version", "target") : [VERSION, nil]
      key = public_key || File.read(File.join(resources || File.expand_path("../..", __dir__), resources ? "update-public.pem" : "packaging/update-public.pem"))
      @key = OpenSSL::PKey.read(key)
      @transport = transport || method(:request)
    end

    def supported? = %w[windows-x64 macos-arm64].include?(@target)

    def check
      bytes = +""
      @transport.call(FEED) do |part|
        bytes << part
        raise Error, "Release metadata is too large" if bytes.bytesize > 65_536
      end
      package = parse(bytes)
      FileUtils.mkdir_p(@directory)
      File.write(File.join(@directory, "release.json"), bytes)
      package
    end

    def cached
      path = File.join(@directory, "release.json")
      return unless File.file?(path) && File.size(path) <= 65_536
      package = parse(File.read(path))
      package if package && verified?(package_path(package), package)
    rescue Error
      nil
    end

    def parse(bytes)
      envelope = JSON.parse(bytes)
      payload = Base64.strict_decode64(envelope.fetch("payload"))
      signature = Base64.strict_decode64(envelope.fetch("signature"))
      raise Error, "Invalid release signature" unless @key.verify(nil, signature, payload)

      release = JSON.parse(payload)
      candidate = release.fetch("version")
      raise Error, "Invalid release version" unless valid_version?(candidate)
      return unless Gem::Version.new(candidate) > Gem::Version.new(@version)

      package = release.fetch("packages").fetch(@target)
      extension = @target == "windows-x64" ? "-setup.exe" : ".dmg"
      expected = "https://github.com/#{REPOSITORY}/releases/download/v#{candidate}/Aljam3-#{candidate}-#{@target}#{extension}"
      raise Error, "Unexpected package URL" unless package.fetch("url") == expected
      raise Error, "Invalid package size" unless package["size"].is_a?(Integer) && (1..MAX_PACKAGE).cover?(package["size"])
      raise Error, "Invalid package checksum" unless /\A[0-9a-f]{64}\z/.match?(package.fetch("sha256"))
      raise Error, "Missing Mac update signature" if @target == "macos-arm64" && Base64.strict_decode64(package.fetch("sparkle_signature")).bytesize != 64

      package.merge("version" => candidate)
    rescue KeyError, TypeError, NoMethodError, JSON::ParserError, ArgumentError, OpenSSL::PKey::PKeyError => error
      raise Error, "Invalid update metadata: #{error.message}"
    end

    def download(package)
      FileUtils.mkdir_p(@directory)
      destination = package_path(package)
      return destination if verified?(destination, package)

      # An interrupted download never becomes executable. Retrying starts afresh.
      partial = "#{destination}.part"
      FileUtils.rm_f(partial)
      count = 0
      File.open(partial, "wb", 0o600) do |file|
        @transport.call(package.fetch("url")) do |part|
          count += part.bytesize
          raise Error, "Package exceeds signed size" if count > package.fetch("size")
          file.write(part)
          yield count.to_f / package.fetch("size") if block_given?
        end
        file.flush
        file.fsync
      end
      raise Error, "Package checksum mismatch" unless verified?(partial, package)
      File.rename(partial, destination)
      # Keep only the current verified package, never a pile of old installers.
      Dir.glob(File.join(@directory, "Aljam3-*" )).each { |path| FileUtils.rm_f(path) if path != destination && File.file?(path) }
      destination
    ensure
      FileUtils.rm_f(partial) if partial
    end

    def verified?(path, package)
      File.file?(path) && File.size(path) == package.fetch("size") && Digest::SHA256.file(path).hexdigest == package.fetch("sha256")
    end

    def package_path(package) = File.join(@directory, File.basename(URI(package.fetch("url")).path))

    # This detached helper waits for orderly shutdown before touching app files.
    def install(package)
      path = package_path(package)
      raise Error, "Downloaded update is no longer valid" unless verified?(path, package)
      helper = File.join(@directory, "helper")
      FileUtils.rm_rf(helper)
      FileUtils.mkdir_p(helper)
      result = File.join(@directory, "result.txt")
      FileUtils.rm_f(result)
      if @target == "windows-x64"
        executable = File.join(helper, "update.exe")
        FileUtils.cp(File.join(@resources, "update.exe"), executable)
        arguments = [File.dirname(@resources), path, package.fetch("sha256"), package.fetch("version"), Process.pid.to_s,
          ENV.fetch("ALJAM3_LAUNCHER_PID", "0"), result]
      else
        app = File.expand_path("../..", @resources)
        FileUtils.cp_r(File.join(app, "Contents/Frameworks"), helper)
        FileUtils.mkdir_p(File.join(helper, "MacOS"))
        executable = File.join(helper, "MacOS/update")
        FileUtils.cp(File.join(@resources, "update"), executable)
        arguments = [app, path, package.fetch("version"), package.fetch("sparkle_signature"), Process.pid.to_s, result]
      end
      log = File.open(File.join(@directory, "install.log"), "w")
      group = @target == "windows-x64" ? { new_pgroup: true } : { pgroup: true }
      pid = Process.spawn([executable, executable], *arguments, chdir: helper, in: File::NULL, out: log, err: log, **group)
      Process.detach(pid)
      true
    ensure
      log&.close
    end

    private

    def valid_version?(value) = value.is_a?(String) && /\A\d+\.\d+\.\d+\z/.match?(value)

    def request(url, redirects = 0, &block)
      uri = URI(url)
      raise Error, "Unsafe update URL" unless uri.scheme == "https" && uri.userinfo.nil? && uri.port == 443
      raise Error, "Too many redirects" if redirects > 5
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "Aljam3/#{@version}", "Accept-Encoding" => "identity" })) do |response|
          case response
          when Net::HTTPSuccess then response.read_body(&block)
          when Net::HTTPRedirection then request(URI.join(url, response.fetch("location")).to_s, redirects + 1, &block)
          else raise Error, "Update server returned #{response.code}"
          end
        end
      end
    end
  end
end
