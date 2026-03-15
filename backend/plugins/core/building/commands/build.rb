# frozen_string_literal: true

module Commands
  module Building
    # Unified build command - routes to specific build subcommands.
    # Acts as a menu/router for all building operations.
    class Build < Commands::Base::Command
      command_name 'build'
      category :building
      help_text 'Build and edit structures'
      usage 'build [subcommand] [args]'
      examples(
        'build',
        'build city',
        'build block',
        'build room <name>',
        'build shop',
        'build apartment',
        'build edit',
        'build rename <name>',
        'build resize <w> <d> <h>',
        'build decorate <desc>',
        'build delete'
      )

      # Build operations grouped by category
      BUILD_OPTIONS = {
        create: [
          { key: '1', label: 'City', cmd: 'build city', desc: 'Create a city with street grid' },
          { key: '2', label: 'Block', cmd: 'build block', desc: 'Add a building block' },
          { key: '3', label: 'Room', cmd: 'build location', desc: 'Create a single room' },
          { key: '4', label: 'Shop', cmd: 'build shop', desc: 'Create a merchant shop' },
          { key: '5', label: 'Apartment', cmd: 'build apartment', desc: 'Create a rentable apartment' }
        ],
        modify: [
          { key: 'e', label: 'Edit', cmd: 'edit room', desc: 'Edit room properties' },
          { key: 'n', label: 'Rename', cmd: 'rename', desc: 'Rename the room' },
          { key: 'r', label: 'Resize', cmd: 'resize room', desc: 'Change room dimensions' },
          { key: 'd', label: 'Decorate', cmd: 'decorate', desc: 'Add decoration' },
          { key: 'x', label: 'Delete', cmd: 'delete room', desc: 'Delete the room' }
        ]
      }.freeze

      protected

      def perform_command(parsed_input)
        error = require_building_permission(error_message: 'Building commands require staff permissions or creator mode.')
        return error if error

        text = (parsed_input[:text] || '').strip
        args = text.split(/\s+/)
        subcommand = args.shift&.downcase

        # If no subcommand, show the quickmenu
        if subcommand.nil? || subcommand.empty?
          return show_build_menu
        end

        # Route to specific build command
        remaining_args = args.join(' ')

        case subcommand
        # Create operations
        when 'city', 'town'
          execute_build_command('build city', remaining_args)
        when 'block', 'building'
          execute_build_command('build block', remaining_args)
        when 'room', 'location'
          execute_build_command('build location', remaining_args)
        when 'shop', 'store'
          execute_build_command('build shop', remaining_args)
        when 'apartment', 'apt'
          execute_build_command('build apartment', remaining_args)

        # Modify operations
        when 'edit', 'settings'
          execute_build_command('edit room', remaining_args)
        when 'rename', 'name'
          execute_build_command('rename', remaining_args)
        when 'resize', 'size'
          execute_build_command('resize room', remaining_args)
        when 'decorate', 'decoration', 'dec'
          execute_build_command('decorate', remaining_args)
        when 'redecorate', 'redec'
          execute_build_command('redecorate', remaining_args)
        when 'delete', 'remove', 'destroy'
          execute_build_command('delete room', remaining_args)

        # Background/seasonal
        when 'background', 'bg'
          execute_build_command('set background', remaining_args)
        when 'seasonal'
          execute_build_command('set seasonal', remaining_args)

        else
          error_result("Unknown build subcommand: #{subcommand}\nType 'build' to see available options.")
        end
      end

      private

      def show_build_menu
        room = character_instance.current_room
        loc = room&.location
        options = []

        # Create section
        options << { key: '-', label: '--- CREATE ---', description: '' }

        # City option - only if no city built yet at this location
        if loc && !loc.city_built_at
          options << { key: '1', label: 'City', description: 'Create a city with street grid' }
        end

        # Block option - only at intersections
        if room&.room_type == 'intersection'
          options << { key: '2', label: 'Block', description: 'Add a building block' }
        end

        options << { key: '3', label: 'Room', description: 'Create a single room' }
        options << { key: '4', label: 'Shop', description: 'Create a merchant shop' }
        options << { key: '5', label: 'Apartment', description: 'Create a rentable apartment' }

        # Modify section (only if we own the room)
        outer_room = room&.outer_room
        if outer_room&.owned_by?(character)
          options << { key: '-', label: '--- MODIFY ---', description: '' }
          options << { key: 'e', label: 'Edit', description: 'Edit room properties' }
          options << { key: 'n', label: 'Rename', description: 'Rename the room' }
          options << { key: 'r', label: 'Resize', description: 'Change room dimensions' }
          options << { key: 'd', label: 'Decorate', description: 'Add decoration' }
          options << { key: 'x', label: 'Delete', description: 'Delete the room' }
        end

        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          'Build Menu',
          options,
          context: {
            command: 'build',
            stage: 'select_type',
            room_id: room&.id,
            location_id: loc&.id
          }
        )
      end

      def execute_build_command(command, args = '')
        full_command = args.empty? ? command : "#{command} #{args}"
        result = Commands::Base::Registry.execute_command(character_instance, full_command)

        if result[:success]
          {
            success: true,
            type: result[:type] || :action,
            message: result[:message],
            interaction_id: result[:interaction_id],
            data: result[:data]
          }
        else
          {
            success: false,
            error: result[:error] || result[:message],
            type: :error
          }
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Build)
