# frozen_string_literal: true

require_relative 'attack'

module Commands
  module Combat
    # Fight command - alias of attack for compatibility.
    class Fight < Attack
      command_name 'fight'
      aliases 'combat', 'engage'
      category :combat
      help_text 'Alias for attack'
      usage 'fight [target]'
      examples 'fight Bob', 'combat goblin', 'engage enemy'
    end
  end
end

Commands::Base::Registry.register(Commands::Combat::Fight)
