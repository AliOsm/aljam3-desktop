# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/updates"

class UpdatesTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("aljam3-updates-")
    @key = OpenSSL::PKey.generate_key("ED25519")
    @body = "verified installer bytes"
    @version = "0.0.2"
    @package = { "url" => "https://github.com/AliOsm/aljam3-desktop/releases/download/v0.0.2/Aljam3-0.0.2-windows-x64-setup.exe",
      "size" => @body.bytesize, "sha256" => Digest::SHA256.hexdigest(@body) }
    @resources = File.join(@directory, "resources")
    FileUtils.mkdir_p(@resources)
    File.write(File.join(@resources, "build.json"), JSON.generate(version: "0.0.1", target: "windows-x64"))
    @calls = []
    @updater = Aljam3::Updates.new(directory: @directory, resources: @resources, public_key: @key.public_to_pem,
      transport: ->(url, &block) { @calls << url; block.call(url == Aljam3::Updates::FEED ? envelope : @body) })
  end

  def teardown = FileUtils.remove_entry(@directory)

  def envelope(key = @key)
    payload = JSON.generate(version: @version, packages: { "windows-x64" => @package })
    JSON.generate(payload: Base64.strict_encode64(payload), signature: Base64.strict_encode64(key.sign(nil, payload)))
  end

  def test_verified_download_and_cache_reuse
    package = @updater.check
    progress = []
    path = @updater.download(package) { |fraction| progress << fraction }
    assert_equal @body, File.binread(path)
    assert_equal [1.0], progress
    assert_equal path, @updater.download(package)
    assert_equal 2, @calls.size
  end

  def test_rejects_untrusted_signer_before_following_package_url
    @key = OpenSSL::PKey.generate_key("ED25519")
    assert_raises(Aljam3::Updates::Error) { @updater.check }
    assert_equal [Aljam3::Updates::FEED], @calls
  end

  def test_refuses_downgrades_and_current_version
    %w[0.0.0 0.0.1].each do |version|
      @version = version
      assert_nil @updater.check
    end
  end

  def test_versions_are_compared_numerically
    @version = "0.0.10"
    @package["url"] = @package["url"].gsub("0.0.2", "0.0.10")
    assert_equal "0.0.10", @updater.check.fetch("version")
  end

  def test_rejects_redirect_to_different_repo_in_signed_metadata
    @package["url"] = @package["url"].sub("AliOsm", "someone")
    assert_raises(Aljam3::Updates::Error) { @updater.check }
  end

  def test_rejects_insecure_transport_even_after_redirect
    assert_raises(Aljam3::Updates::Error) { @updater.send(:request, "http://github.com/update") {} }
    assert_raises(Aljam3::Updates::Error) { @updater.send(:request, "file:///tmp/update") {} }
    assert_raises(Aljam3::Updates::Error) { @updater.send(:request, "https://github.com/update", 6) {} }
  end

  def test_rejects_corrupt_or_truncated_downloads_and_removes_partial_files
    package = @updater.check
    ["corrupt installer bytes!!", "truncated", ""].each do |body|
      @body = body
      assert_raises(Aljam3::Updates::Error) { @updater.download(package) }
      refute File.exist?(@updater.package_path(package))
      assert_empty Dir.glob(File.join(@updater.directory, "*.part"))
    end
  end

  def test_corrupted_cached_package_is_downloaded_again
    package = @updater.check
    path = @updater.download(package)
    File.write(path, "damaged")
    assert_equal path, @updater.download(package)
    assert_equal @body, File.read(path)
    assert_equal 3, @calls.size
  end

  def test_refuses_install_if_verified_package_was_changed
    package = @updater.check
    path = @updater.download(package)
    File.write(path, "damaged")
    assert_raises(Aljam3::Updates::Error) { @updater.install(package) }
    refute File.exist?(File.join(@updater.directory, "helper"))
  end

  def test_does_not_trust_oversized_signed_metadata
    @package["size"] = Aljam3::Updates::MAX_PACKAGE + 1
    assert_raises(Aljam3::Updates::Error) { @updater.check }
  end

  def test_rejects_malformed_versions_and_hashes
    @version = "../0.0.2"
    assert_raises(Aljam3::Updates::Error) { @updater.check }
    @version = "0.0.2"
    @package["sha256"] = "invalid"
    assert_raises(Aljam3::Updates::Error) { @updater.check }
  end

  def test_source_checkout_is_not_updated
    source = Aljam3::Updates.new(directory: @directory, resources: nil)
    refute source.supported?
    assert_equal Aljam3::VERSION, source.version
  end
end
