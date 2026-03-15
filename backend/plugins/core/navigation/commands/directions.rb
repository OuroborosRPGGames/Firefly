# frozen_string_literal: true

module Commands
  module Navigation
    # Base class for direction commands
    class DirectionCommand < Commands::Base::Command
      category :navigation

      requires :not_in_combat, message: "You can't leave while in combat! Use fight commands instead."

      class << self
        def direction
          raise NotImplementedError, 'Subclasses must define direction'
        end
      end

      protected

      def perform_command(_parsed_input)
        walk_command = Walk.new(character_instance, request_env: request_env)
        walk_command.execute("walk #{self.class.direction}")
      end
    end

    class North < DirectionCommand
      command_name 'north'
      aliases 'n'
      help_text 'Move north to an adjacent room'
      usage 'north'
      examples 'north', 'n'

      def self.direction
        'north'
      end
    end

    class South < DirectionCommand
      command_name 'south'
      aliases 's'
      help_text 'Move south to an adjacent room'
      usage 'south'
      examples 'south', 's'

      def self.direction
        'south'
      end
    end

    class East < DirectionCommand
      command_name 'east'
      aliases 'e'
      help_text 'Move east to an adjacent room'
      usage 'east'
      examples 'east', 'e'

      def self.direction
        'east'
      end
    end

    class West < DirectionCommand
      command_name 'west'
      aliases 'w'
      help_text 'Move west to an adjacent room'
      usage 'west'
      examples 'west', 'w'

      def self.direction
        'west'
      end
    end

    class Up < DirectionCommand
      command_name 'up'
      aliases 'u'
      help_text 'Move up to a room above'
      usage 'up'
      examples 'up', 'u'

      def self.direction
        'up'
      end
    end

    class Down < DirectionCommand
      command_name 'down'
      aliases 'd'
      help_text 'Move down to a room below'
      usage 'down'
      examples 'down', 'd'

      def self.direction
        'down'
      end
    end

    class Northeast < DirectionCommand
      command_name 'northeast'
      aliases 'ne'
      help_text 'Move northeast to an adjacent room'
      usage 'northeast'
      examples 'northeast', 'ne'

      def self.direction
        'northeast'
      end
    end

    class Northwest < DirectionCommand
      command_name 'northwest'
      aliases 'nw'
      help_text 'Move northwest to an adjacent room'
      usage 'northwest'
      examples 'northwest', 'nw'

      def self.direction
        'northwest'
      end
    end

    class Southeast < DirectionCommand
      command_name 'southeast'
      aliases 'se'
      help_text 'Move southeast to an adjacent room'
      usage 'southeast'
      examples 'southeast', 'se'

      def self.direction
        'southeast'
      end
    end

    class Southwest < DirectionCommand
      command_name 'southwest'
      aliases 'sw'
      help_text 'Move southwest to an adjacent room'
      usage 'southwest'
      examples 'southwest', 'sw'

      def self.direction
        'southwest'
      end
    end

    class In < DirectionCommand
      command_name 'in'
      aliases 'enter', 'inside'
      help_text 'Move inside or inward to an adjacent interior room'
      usage 'in'
      examples 'in', 'enter', 'inside'

      def self.direction
        'in'
      end
    end

    class Out < DirectionCommand
      command_name 'out'
      aliases 'exit', 'outside', 'leave'
      help_text 'Move outside or outward to an adjacent exterior room'
      usage 'out'
      examples 'out', 'exit', 'outside'

      def self.direction
        'out'
      end
    end
  end
end

# Auto-register all direction commands
Commands::Base::Registry.register(Commands::Navigation::North)
Commands::Base::Registry.register(Commands::Navigation::South)
Commands::Base::Registry.register(Commands::Navigation::East)
Commands::Base::Registry.register(Commands::Navigation::West)
Commands::Base::Registry.register(Commands::Navigation::Up)
Commands::Base::Registry.register(Commands::Navigation::Down)
Commands::Base::Registry.register(Commands::Navigation::Northeast)
Commands::Base::Registry.register(Commands::Navigation::Northwest)
Commands::Base::Registry.register(Commands::Navigation::Southeast)
Commands::Base::Registry.register(Commands::Navigation::Southwest)
Commands::Base::Registry.register(Commands::Navigation::In)
Commands::Base::Registry.register(Commands::Navigation::Out)
