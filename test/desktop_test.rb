# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require_relative "../lib/aljam3/desktop"

class DesktopTest < Minitest::Test
  def test_revealing_a_file_preserves_unicode_and_spaces_without_a_shell
    Dir.mktmpdir("aljam3-reveal-") do |directory|
      path = File.join(directory, "علي فاضل", "كتاب العلم.pdf")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "sample")
      [false, true].each do |windows|
        expected = if windows
          ["explorer.exe", File.dirname(path).tr("/", "\\")]
        elsif RUBY_PLATFORM.include?("darwin")
          ["open", "-R", path]
        else
          ["xdg-open", File.dirname(path)]
        end
        launch = ->(*argv, **options) do
          assert_equal expected, argv
          assert_equal({ out: File::NULL, err: File::NULL }, options)
          123
        end
        Gem.stub(:win_platform?, windows) do
          Process.stub(:spawn, launch) do
            Process.stub(:detach, ->(pid) { assert_equal 123, pid }) { Aljam3::Desktop.reveal(path) }
          end
        end
      end
    end
  end

  def test_missing_files_do_not_launch_the_desktop
    Process.stub(:spawn, ->(*) { flunk "Missing files must not open the file manager" }) do
      assert_raises(Errno::ENOENT) { Aljam3::Desktop.reveal(File.join(Dir.tmpdir, "aljam3-missing-file")) }
    end
  end
end
