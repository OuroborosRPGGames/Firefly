# frozen_string_literal: true

module Commands
  module Navigation
    class Landmarks < Commands::Base::Command
      command_name 'landmarks'
      aliases 'public', 'locations', 'destinations'
      category :navigation
      help_text 'List public places you can walk to'
      usage 'landmarks'
      examples 'landmarks', 'public', 'locations'

      protected

      def perform_command(_parsed_input)
        zone = location.location&.zone
        return error_result("You're not in a defined zone.") unless zone

        # Find all public rooms in this zone (rooms without owners)
        rooms = find_public_rooms(zone)

        if rooms.empty?
          return error_result("No public landmarks found in #{zone.name}.")
        end

        format_landmarks(zone, rooms)
      end

      private

      def find_public_rooms(zone)
        # Get all rooms in this zone via their locations that have no owner
        Room.join(:locations, id: :location_id)
            .where(Sequel[:locations][:zone_id] => zone.id)
            .where(Sequel[:rooms][:owner_id] => nil)
            .select_all(:rooms)
            .eager(:location)
            .order(Sequel[:rooms][:name])
            .all
      end

      def format_landmarks(zone, rooms)
        lines = ["<h4>Public Places in #{zone.name}</h4>"]

        # Group by location
        by_location = rooms.group_by { |room| room.location&.name || 'Unknown' }

        by_location.keys.sort.each do |loc_name|
          lines << "#{loc_name}:"
          by_location[loc_name].each do |room|
            # Add room type indicator
            type_indicator = room_type_icon(room.room_type)
            lines << "  #{type_indicator} #{room.name}"
          end
          lines << ""
        end

        lines << "#{rooms.length} public place(s) listed."
        lines << "Use 'walk <place name>' to travel there."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'landmarks',
            zone_id: zone.id,
            zone_name: zone.name,
            count: rooms.length,
            landmarks: rooms.map { |r| room_data(r) }
          }
        )
      end

      def room_type_icon(room_type)
        RoomTypeConfig.icon(room_type)
      end

      def room_data(room)
        {
          id: room.id,
          name: room.name,
          room_type: room.room_type,
          location_name: room.location&.name,
          short_description: room.short_description
        }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Landmarks)
