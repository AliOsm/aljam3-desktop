# frozen_string_literal: true

require_relative "lib/aljam3"
require_relative "lib/aljam3/ui"
require_relative "lib/aljam3/language"

Shoes.app(title: Aljam3::Language.app_name, width: 1160, height: 820, icon: File.join(Aljam3::ROOT, "assets/brand/app-icon.png")) do
  extend Aljam3::UI
  setup
end
