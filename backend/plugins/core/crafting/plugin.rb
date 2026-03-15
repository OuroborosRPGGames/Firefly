# frozen_string_literal: true

module Plugins
  module Crafting
    class Plugin < Firefly::Plugin
      name :crafting
      version '1.0.0'
      description 'Crafting and creation commands: fabricate, make'
      commands_path 'commands'
    end
  end
end
