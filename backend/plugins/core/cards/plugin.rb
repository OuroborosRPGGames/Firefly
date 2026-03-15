# frozen_string_literal: true

module Plugins
  module Cards
    class Plugin < Firefly::Plugin
      name :cards
      version '1.0.0'
      description 'Card game commands: getdeck, deal, draw, playcard, discard, and more'
      commands_path 'commands'
    end
  end
end
