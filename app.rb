# frozen_string_literal: true

require_relative "lib/aljam3"
require_relative "lib/aljam3/ui"

Shoes.app(title: "الجامع · Aljam3", width: 1160, height: 820, icon: File.join(Aljam3::ROOT, "assets/brand/app-icon.png")) do
  extend Aljam3::UI
  setup
end
