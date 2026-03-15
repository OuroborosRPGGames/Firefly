# frozen_string_literal: true

module Commands
  module Building
    class BuildLocation < Commands::Base::Command
      command_name 'build location'
      aliases 'build building', 'create location'
      category :building
      help_text 'Build a new location (building) with an entry room'
      usage 'build location <name>'
      examples 'build location Town Hall', 'build building Market Square'

      protected

      def perform_command(parsed_input)
        error = require_building_permission(error_message: "You must be in creator mode or be staff to build locations. Use 'creator mode' first.")
        return error if error

        # Parse location name
        name = (parsed_input[:text] || '').sub(/^(location|building)\s*/i, '').strip

        if name.empty?
          return error_result('What do you want to name this location? Usage: build location <name>')
        end

        if name.length > 100
          return error_result('Location name must be 100 characters or less.')
        end

        # Get current zone from location hierarchy
        current_zone = location.location&.zone
        unless current_zone
          return error_result('Cannot determine current zone. Please move to a valid location first.')
        end

        # Check if location name already exists in this zone
        if Location.where(zone_id: current_zone.id, name: name).count.positive?
          return error_result("A location named '#{name}' already exists in this zone.")
        end

        # Create the location
        new_location = Location.create(
          zone_id: current_zone.id,
          name: name,
          description: "A newly constructed location.",
          location_type: 'building',
          active: true
        )

        # Create an entry room inside the location
        entry_room = Room.create(
          location_id: new_location.id,
          name: 'Entry',
          short_description: "The entry to #{name}.",
          long_description: "You stand in the entry of #{name}. The space is bare and waiting to be decorated.",
          room_type: 'standard',
          owner_id: character.id,
          min_x: -5.0,
          max_x: 5.0,
          min_y: -5.0,
          max_y: 5.0,
          min_z: 0.0,
          max_z: 3.0,
          active: true
        )

        # Move character to the new room
        character_instance.update(current_room_id: entry_room.id, x: 0.0, y: 0.0, z: 0.0)

        actor_name = character.full_name

        # Broadcast departure from old room
        BroadcastService.to_room(
          location.id,
          "#{actor_name} disappears as they create a new building.",
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You have created '#{name}' with an entry room. You are now in the entry room and own this building. " \
          "Use building commands to customize it.",
          type: :action,
          data: {
            action: 'build_location',
            location_id: new_location.id,
            location_name: name,
            room_id: entry_room.id,
            room_name: entry_room.name,
            owner_id: character.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::BuildLocation)
