# frozen_string_literal: true

require "open3"

module Aljam3
  module UI
    CARD_RADIUS = 6
    FONT = "Noto Naskh Arabic UI"
    HEADING_FONT = "thmanyah serif display 500"
    READING_FONT = "Kitab"

    module Theme
      # Both palettes are Aljam3's OKLCH tokens converted to sRGB.
      PALETTES = {
        light: { paper: "#ffffff", card_color: "#ffffff", ink: "#4e3f3b", muted: "#827b78",
                 primary: "#ae4721", accent: "#f5e9e1", surface: "#f9f8f8", line_color: "#ede6dc" },
        dark: { paper: "#1e1b1a", card_color: "#2c2828", ink: "#ffffff", muted: "#b6b2b0",
                primary: "#e16e4a", accent: "#284d53", surface: "#2c2828", line_color: "#4a4543" }
      }.freeze

      PALETTES.fetch(:light).each_key do |name|
        define_method(name) { PALETTES.fetch(@theme || :light).fetch(name) }
      end

      def initial_theme
        (@store.preference("theme") || system_theme).to_sym
      end

      def system_theme
        return windows_theme if Gem.win_platform?

        command = if RUBY_PLATFORM.include?("darwin")
          ["defaults", "read", "-g", "AppleInterfaceStyle"]
        else
          ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
        end
        value, status = Open3.capture2(*command, err: File::NULL)
        status.success? && value.match?(/dark/i) ? :dark : :light
      rescue Errno::ENOENT
        :light
      end

      def windows_theme
        require "win32/registry"

        Win32::Registry::HKEY_CURRENT_USER.open('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize') do |key|
          key.read_i("AppsUseLightTheme").zero? ? :dark : :light
        end
      rescue Win32::Registry::Error, TypeError
        :light
      end

      def apply_theme
        style(Shoes::Para, font: FONT, size: 16, stroke: ink, margin: 0, align: "right", owns_text: true)
        style(Shoes::Button, font: FONT, size: 15, height: 36)
        style(Shoes::EditLine, font: "#{FONT} 17", height: 40, stroke: ink, fill: card_color, border_color: line_color)
        style(Shoes::Link, stroke: ink, underline: "none")
        style(Shoes::Stack, scrollbar_color: muted)
        style(Shoes::Progress, color: primary, background_color: line_color, direction: "rtl", height: 8)
      end

      def toggle_theme
        @theme = @theme == :dark ? :light : :dark
        @store.save_preference("theme", @theme.to_s)
        apply_theme
        draw_window
      end

      def asset_path(kind, name, theme: @theme)
        suffix = theme == :dark ? "-dark" : ""
        File.join(ROOT, "assets", kind, "#{name}#{suffix}.png")
      end
    end
  end
end
