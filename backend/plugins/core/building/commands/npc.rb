# frozen_string_literal: true

module Commands
  module Building
    # Unified NPC management command.
    # Replaces: add_npc_location.rb, save_npc_location.rb, npc_locations.rb, delete_npc_location.rb
    class Npc < Commands::Base::Command
      command_name 'npc'
      aliases 'npclocation', 'npcloc'
      category :building
      help_text 'Manage NPC spawn locations and schedules'
      usage 'npc [subcommand] [args]'
      examples(
        'npc',
        'npc location add',
        'npc location save Guard Post',
        'npc location list',
        'npc location del Guard Post'
      )

      protected

      def perform_command(parsed_input)
        error = require_building_permission(error_message: 'You need building permissions to manage NPC locations.')
        return error if error

        args = (parsed_input[:text] || '').strip.split(/\s+/)
        subcommand = args.shift&.downcase
        sub_args = args

        current_user = character.user

        case subcommand
        when nil, '', 'help'
          show_help
        when 'location', 'loc'
          handle_location_subcommand(sub_args, current_user)
        when 'add'
          # Direct shortcut: npc add
          handle_location_add(sub_args.join(' '), current_user)
        when 'list', 'ls'
          # Direct shortcut: npc list
          handle_location_list(current_user)
        when 'save'
          # Direct shortcut: npc save <name>
          handle_location_save(sub_args.join(' '), current_user)
        when 'del', 'delete', 'remove'
          # Direct shortcut: npc del <name>
          handle_location_delete(sub_args.join(' '), current_user)
        else
          error_result("Unknown subcommand: #{subcommand}\nUse 'npc' for help.")
        end
      end

      # Handle form response for adding NPC schedule
      def handle_form_response(form_data, context)
        archetype = NpcArchetype[context['archetype_id']]
        room = Room[context['room_id']]
        user = character_instance.character.user

        return error_result('Invalid archetype or room.') unless archetype && room

        # Get or create an NPC from this archetype
        npc = archetype.characters.first || archetype.create_unique_npc(archetype.name)

        # Create the schedule
        schedule = NpcSchedule.create(
          character_id: npc.id,
          room_id: room.id,
          activity: form_data['activity'],
          start_hour: form_data['start_hour']&.to_i || 0,
          end_hour: form_data['end_hour']&.to_i || 24,
          weekdays: form_data['weekdays'] || 'all',
          probability: form_data['probability']&.to_i || 100,
          max_npcs: 1,
          is_active: true
        )

        # Optionally save to location library
        if form_data['save_to_library'] == 'true' && !form_data['library_name'].to_s.strip.empty?
          begin
            NpcSpawnLocation.create(
              user_id: user.id,
              room_id: room.id,
              name: form_data['library_name']
            )
          rescue StandardError => e
            warn "[NpcCommand] Failed to save spawn location to library: #{e.message}"
          end
        end

        success_result(
          "Schedule created! #{archetype.name} will appear in #{room.name}.",
          type: :message,
          data: {
            action: 'npc_schedule_created',
            archetype_id: archetype.id,
            schedule_id: schedule.id,
            room_id: room.id
          }
        )
      end

      private

      def show_help
        lines = [
          'NPC Management Commands:',
          '',
          'Location management:',
          '  npc location add           - Add current room as NPC schedule location',
          '  npc location save <name>   - Save current room to location library',
          '  npc location list          - List saved locations',
          '  npc location del <name>    - Delete from location library',
          '',
          'Shortcuts:',
          '  npc add                    - Same as npc location add',
          '  npc list                   - Same as npc location list',
          '  npc save <name>            - Same as npc location save',
          '  npc del <name>             - Same as npc location del'
        ]
        success_result(lines.join("\n"), type: :message)
      end

      def handle_location_subcommand(args, user)
        action = args.shift&.downcase
        remaining = args.join(' ')

        case action
        when 'add', 'create'
          handle_location_add(remaining, user)
        when 'save'
          handle_location_save(remaining, user)
        when 'list', 'ls'
          handle_location_list(user)
        when 'del', 'delete', 'remove'
          handle_location_delete(remaining, user)
        else
          error_result("Unknown location subcommand: #{action}\nUse 'npc' for help.")
        end
      end

      # ========================================
      # Location Add (from add_npc_location.rb)
      # ========================================

      def handle_location_add(npc_name, user)
        room = location

        if npc_name && !npc_name.empty?
          npcs = accessible_npcs(user)
          npc = npcs.find { |n| n.name.downcase == npc_name.downcase }

          unless npc
            return error_result("NPC archetype '#{npc_name}' not found or you don't have access.")
          end

          return show_schedule_form(npc, room)
        end

        # Show quickmenu of accessible NPCs
        npcs = accessible_npcs(user)

        if npcs.empty?
          return error_result('You have no NPC archetypes to configure. Create one in the admin panel first.')
        end

        options = npcs.first(10).map do |npc|
          {
            key: npc.id.to_s,
            label: npc.name,
            description: "#{npc.behavior_pattern || 'neutral'} - #{npc.characters_dataset.count} NPCs"
          }
        end

        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          "Select an NPC archetype to add #{room.name} as a schedule location:",
          options,
          context: {
            command: 'npc',
            stage: 'select_archetype',
            room_id: room.id
          }
        )
      end

      # ========================================
      # Location Save (from save_npc_location.rb)
      # ========================================

      def handle_location_save(name, user)
        if name.empty?
          return error_result("Please provide a name. Usage: npc location save <name>")
        end

        room = location

        # Check for duplicate
        existing = NpcSpawnLocation.first(user_id: user.id) { Sequel.ilike(:name, name) }
        if existing
          return error_result("You already have a location named '#{name}' in your library.")
        end

        loc = NpcSpawnLocation.create(
          user_id: user.id,
          room_id: room.id,
          name: name
        )

        success_result(
          "Saved '#{name}' (#{room.name}) to your NPC location library.",
          type: :message,
          data: {
            action: 'location_saved',
            location_id: loc.id,
            room_id: room.id,
            name: name
          }
        )
      rescue Sequel::ValidationFailed => e
        error_result("Failed to save location: #{e.message}")
      end

      # ========================================
      # Location List (from npc_locations.rb)
      # ========================================

      def handle_location_list(user)
        locations = NpcSpawnLocation.for_user(user).eager(:room).all

        if locations.empty?
          return success_result(
            "Your NPC location library is empty.\nUse 'npc location save <name>' to add the current room.",
            type: :message
          )
        end

        lines = ['Your saved NPC spawn locations:', '']
        locations.each do |loc|
          room_name = loc.room&.name || 'Unknown Room'
          area_name = loc.room&.location&.name
          area_suffix = area_name ? " (#{area_name})" : ''
          lines << "  #{loc.name}: #{room_name}#{area_suffix}"
          lines << "    #{loc.notes}" if loc.notes && !loc.notes.empty?
        end
        lines << ''
        lines << "Total: #{locations.count} location(s)"

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'list_locations',
            count: locations.count,
            locations: locations.map do |loc|
              {
                id: loc.id,
                name: loc.name,
                room_id: loc.room_id,
                room_name: loc.room&.name,
                notes: loc.notes
              }
            end
          }
        )
      end

      # ========================================
      # Location Delete (from delete_npc_location.rb)
      # ========================================

      def handle_location_delete(name, user)
        if name.empty?
          return error_result("Please specify which location to remove. Usage: npc location del <name>")
        end

        loc = NpcSpawnLocation.find_by_name(user, name)

        unless loc
          return error_result("No location named '#{name}' found in your library.")
        end

        room_name = loc.room&.name || 'Unknown'
        loc.destroy

        success_result(
          "Removed '#{loc.name}' (#{room_name}) from your NPC location library.",
          type: :message,
          data: {
            action: 'location_deleted',
            name: loc.name
          }
        )
      end

      # ========================================
      # Helpers
      # ========================================

      def accessible_npcs(user)
        if user.can_manage_npcs?
          NpcArchetype.order(:name).all
        else
          NpcArchetype.where(created_by_id: user.id).order(:name).all
        end
      end

      def show_schedule_form(archetype, room)
        fields = [
          {
            name: 'activity',
            label: 'Activity Description',
            type: 'text',
            placeholder: 'e.g., standing guard at the gate',
            required: false
          },
          {
            name: 'start_hour',
            label: 'Start Hour',
            type: 'select',
            default: '0',
            options: (0..23).map { |h| { value: h.to_s, label: format('%02d:00', h) } }
          },
          {
            name: 'end_hour',
            label: 'End Hour',
            type: 'select',
            default: '24',
            options: (1..24).map { |h| { value: h.to_s, label: h == 24 ? '24:00 (midnight)' : format('%02d:00', h) } }
          },
          {
            name: 'weekdays',
            label: 'Days Active',
            type: 'select',
            default: 'all',
            options: NpcSchedule::WEEKDAY_PATTERNS.map { |p| { value: p, label: p.capitalize } }
          },
          {
            name: 'probability',
            label: 'Spawn Probability %',
            type: 'number',
            default: '100',
            min: 0,
            max: 100
          },
          {
            name: 'save_to_library',
            label: 'Save location to my library?',
            type: 'select',
            default: 'false',
            options: [
              { value: 'false', label: 'No' },
              { value: 'true', label: 'Yes' }
            ]
          },
          {
            name: 'library_name',
            label: 'Library Name (if saving)',
            type: 'text',
            placeholder: 'Name for this location',
            required: false
          }
        ]

        create_form(
          character_instance,
          "Add #{archetype.name} to #{room.name}",
          fields,
          context: {
            command: 'npc',
            stage: 'schedule_form',
            archetype_id: archetype.id,
            room_id: room.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::Npc)
