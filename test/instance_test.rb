# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/instance"
require "open3"
require "timeout"

class InstanceTest < Minitest::Test
  def test_only_one_instance_owns_a_directory_and_shutdown_allows_reopening
    Dir.mktmpdir("aljam3-instance-") do |directory|
      instance = Aljam3::Instance.acquire(directory)
      refute_nil instance
      assert_nil Aljam3::Instance.acquire(directory)
      other = Aljam3::Instance.acquire(File.join(directory, "another library"))
      refute_nil other
      other.close
      instance.close
      instance.close
      reopened = Aljam3::Instance.acquire(directory)
      refute_nil reopened
      reopened.close
    ensure
      instance&.close
      other&.close
      reopened&.close
    end
  end

  def test_another_process_cannot_own_the_library_until_the_owner_exits
    Dir.mktmpdir("aljam3-instance-") do |directory|
      path = File.join(directory, "مكتبة علي")
      script = <<~RUBY
        require #{File.expand_path('../lib/aljam3/instance', __dir__).dump}
        instance = Aljam3::Instance.acquire(ARGV.fetch(0))
        abort 'no lock' unless instance
        $stdout.sync = true
        puts 'ready'
        STDIN.read
      RUBY
      Open3.popen3(RbConfig.ruby, "-e", script, path) do |input, output, _error, child|
        assert_equal "ready\n", Timeout.timeout(5) { output.gets }
        assert_nil Aljam3::Instance.acquire(path)
        Process.kill("KILL", child.pid)
        child.join
        recovered = Aljam3::Instance.acquire(path)
        refute_nil recovered, "the OS must release a crashed owner's lock"
        recovered.close
      ensure
        input.close unless input.closed?
        Process.kill("KILL", child.pid) if child.alive?
        child.join
        recovered&.close
      end
    end
  end
end
