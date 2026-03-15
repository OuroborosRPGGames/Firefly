# frozen_string_literal: true

module Commands
  module Communication
    class Knock < Commands::Base::Command
      command_name 'knock'
      category :roleplaying
      help_text 'Knock on a door to alert people in another room'
      usage 'knock <direction/exit>'
      examples 'knock north', 'knock bedroom'

      protected

      def perform_command(parsed_input)
        target_text = (parsed_input[:text] || '').strip

        if target_text.empty?
          return error_result('Knock on what? Usage: knock <direction/exit>')
        end

        room = location

        # Build exit list from spatial adjacency
        spatial_exits = room.spatial_exits
        exits = spatial_exits.flat_map do |direction, rooms|
          rooms.map do |to_room|
            OpenStruct.new(
              direction: direction.to_s,
              to_room: to_room,
              display_name: to_room.name
            )
          end
        end

        if exits.empty?
          return error_result('There are no exits to knock on here.')
        end

        # Try to find matching exit
        target_exit = find_exit(exits, target_text)

        unless target_exit
          return error_result("No exit like '#{target_text}' found.")
        end

        target_room = target_exit.to_room
        unless target_room
          return error_result('That exit leads nowhere.')
        end

        # Get the outer property (for apartments/properties with multiple rooms)
        outer_room = target_room.outer_room

        # Message to current room
        here_message = "#{character.full_name} knocks on the door to #{target_exit.display_name}."

        # Broadcast to current room (personalized per viewer)
        broadcast_to_room(here_message, exclude_character: character_instance, type: :emote)

        # Message to target room(s)
        there_message = "You hear knocking from #{room.name}."

        # Find all characters in the target property (same outer room)
        target_characters = CharacterInstance
          .where(online: true, reality_id: character_instance.reality_id)
          .join(:rooms, id: :current_room_id)
          .where(Sequel[:rooms][:id] => outer_room.id)
          .or(Sequel[:rooms][:inside_room_id] => outer_room.id)
          .exclude(Sequel[:character_instances][:id] => character_instance.id)

        # Also check the target room directly if it's not nested
        if outer_room.id == target_room.id
          target_characters = CharacterInstance
            .where(online: true, reality_id: character_instance.reality_id)
            .where(current_room_id: target_room.id)
            .exclude(id: character_instance.id)
        end

        # Send knock message to each target
        target_characters.each do |target_ci|
          BroadcastService.to_character(
            target_ci,
            there_message,
            type: :notification
          )
        end

        success_result(
          here_message,
          type: :message,
          data: {
            action: 'knock',
            target_direction: target_exit.direction,
            target_room: target_room.name
          }
        )
      end

      private

      def find_exit(exits, target_text)
        target_lower = target_text.downcase

        # Try exact direction match first
        exits.find { |ex| ex.direction.downcase == target_lower } ||
          # Then try partial direction match
          exits.find { |ex| ex.direction.downcase.start_with?(target_lower) } ||
          # Then try exit name match
          exits.find { |ex| ex.display_name.downcase == target_lower } ||
          # Then try partial name match
          exits.find { |ex| ex.display_name.downcase.include?(target_lower) } ||
          # Then try room name match
          exits.find { |ex| ex.to_room&.name&.downcase&.include?(target_lower) }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Knock)
