# frozen_string_literal: true

module Commands
  module Navigation
    class Enter < Commands::Base::Command
      command_name 'enter'
      aliases 'go into', 'walk into'
      category :navigation
      help_text 'Enter a location by name'
      usage 'enter <location>'
      examples 'enter coffee shop', 'enter lobby'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]&.strip

        if target.nil? || target.empty?
          return error_result('Enter where? Specify a location name.')
        end

        destination = RoomAdjacencyService.resolve_named_movement(location, target)

        unless destination
          return error_result("You can't find '#{target}' from here.")
        end

        perform_entry(destination)
      end

      private

      def perform_entry(destination)
        old_room = location

        # Calculate arrival position (center of destination)
        arrival_pos = {
          x: (destination.min_x.to_f + destination.max_x.to_f) / 2.0,
          y: (destination.min_y.to_f + destination.max_y.to_f) / 2.0,
          z: destination.min_z.to_f
        }

        # Broadcast departure
        broadcast_departure("#{character.full_name} enters #{destination.name}.")

        # Move character
        character_instance.update(
          current_room_id: destination.id,
          x: arrival_pos[:x],
          y: arrival_pos[:y],
          z: arrival_pos[:z]
        )

        @location = destination

        # Broadcast arrival
        broadcast_arrival("#{character.full_name} enters.")

        # Send minimap update for the new room
        MovementService.notify_room_arrival(character_instance, destination)

        # Show new room
        look_command = Look.new(character_instance, request_env: request_env)
        look_result = look_command.execute('look')

        look_result.merge(
          moved_from: old_room.id,
          moved_to: destination.id,
          action: 'enter'
        )
      end

      def broadcast_departure(message)
        room_characters = CharacterInstance.where(current_room_id: location&.id)
                                           .where(online: true)
                                           .exclude(id: character_instance.id)
                                           .eager(:character)

        room_characters.each do |viewer_instance|
          personalized_msg = substitute_name_for_viewer(message, viewer_instance)
          send_to_character(viewer_instance, personalized_msg)
        end
      end

      def broadcast_arrival(message)
        room_characters = CharacterInstance.where(current_room_id: @location&.id)
                                           .where(online: true)
                                           .exclude(id: character_instance.id)
                                           .eager(:character)

        room_characters.each do |viewer_instance|
          personalized_msg = substitute_name_for_viewer(message, viewer_instance)
          send_to_character(viewer_instance, personalized_msg)
        end
      end

      def substitute_name_for_viewer(message, viewer_instance)
        display_name = character.display_name_for(viewer_instance)
        message.gsub(character.full_name, display_name)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Enter)
