# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/aljam3/ui/theme"
require "minitest/mock"
require "win32/registry" if Gem.win_platform?

class ThemeTest < StoreTestCase
  def setup
    super
    @view = Object.new.extend(Aljam3::UI::Theme)
    @view.instance_variable_set(:@store, @store)
  end

  def test_saved_theme_does_not_query_the_operating_system
    @view.stub(:system_theme, -> { flunk "A saved theme must not query the OS" }) do
      %w[light dark].each do |theme|
        @store.save_preference("theme", theme)
        assert_equal theme.to_sym, @view.initial_theme
      end
    end
  end

  def test_first_launch_uses_the_system_theme
    %i[light dark].each do |theme|
      @view.stub(:system_theme, theme) { assert_equal theme, @view.initial_theme }
    end
    assert_nil @store.preference("theme")
  end

  if Gem.win_platform?
    def test_windows_reads_the_theme_without_starting_a_process
      Open3.stub(:capture2, ->(*) { flunk "Theme detection must not launch a console command" }) do
        { 0 => :dark, 1 => :light }.each do |value, theme|
          key = Minitest::Mock.new
          key.expect(:read_i, value, ["AppsUseLightTheme"])
          open = lambda do |path, &block|
            assert_equal 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', path
            block.call(key)
          end
          Win32::Registry::HKEY_CURRENT_USER.stub(:open, open) do
            assert_equal theme, @view.system_theme
          end
          key.verify
        end
      end
    end

    def test_unavailable_or_invalid_windows_theme_defaults_to_light
      [Win32::Registry::Error.new(2), Win32::Registry::Error.new(5), TypeError.new("Invalid registry type")].each do |error|
        Win32::Registry::HKEY_CURRENT_USER.stub(:open, ->(*) { raise error }) do
          assert_equal :light, @view.system_theme
        end
      end
    end
  end
end
