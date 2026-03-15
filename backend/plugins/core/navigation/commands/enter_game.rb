# frozen_string_literal: true

module Commands
  module Navigation
    class EnterGame < Commands::Base::Command
      command_name 'enter game'
      aliases 'entergame', 'enter world', 'start game', 'begin'
      category :navigation
      help_text 'Leave the tutorial and enter the game world'
      usage 'enter game'
      examples 'enter game', 'enter world'

      # The Exit Hall room ID where this command works
      EXIT_HALL_ROOM_ID = 28
      EXIT_HALL_ROOM_NAME = 'Exit Hall'

      # The starting village name
      STARTING_VILLAGE_NAME = 'New Haven'

      protected

      def perform_command(_parsed_input)
        # Check if player is in the Exit Hall (by ID or name)
        unless location.id == EXIT_HALL_ROOM_ID || location.name == EXIT_HALL_ROOM_NAME
          return error_result(
            "You can only enter the game world from the Exit Hall. " \
            "Complete the tutorial first!"
          )
        end

        # Find the destination room - prioritize New Haven village
        destination = find_destination
        unless destination
          return error_result(
            "The game world isn't ready yet. Please contact staff."
          )
        end

        # Get the village/location name
        village_name = destination.location&.city_name || destination.location&.name || "the village"

        # Teleport the player
        character_instance.teleport_to_room!(destination)

        # Broadcast departure from Exit Hall
        broadcast_to_room(
          "#{character.full_name} steps through the shimmering portal and vanishes into the world beyond.",
          exclude: [character_instance]
        )

        # Send minimap update for the new room
        MovementService.notify_room_arrival(character_instance, destination)

        success_result(
          "You step through the portal...\n\n" \
          "The world shifts around you, and suddenly you find yourself standing " \
          "at a crossroads in #{village_name}. The scent of fresh bread drifts from " \
          "a nearby tavern, and you can hear the distant clang of a blacksmith's hammer.\n\n" \
          "Welcome to the world! Use <b>look</b> to see your surroundings.",
          type: :action,
          data: {
            action: 'enter_game',
            from_room_id: location.id,
            to_room_id: destination.id,
            village_name: village_name
          }
        )
      end

      private

      def find_destination
        # Priority 1: Admin-configured specific room
        configured_room_id = GameSetting.integer('spawn_room_id')
        if configured_room_id
          room = Room[configured_room_id]
          return room if room
        end

        # Priority 2: Admin-configured location (find best room in it)
        configured_location_id = GameSetting.integer('spawn_location_id')
        if configured_location_id
          room = find_best_room_in_location(configured_location_id)
          return room if room
        end

        # Priority 3: Hardcoded fallbacks - New Haven
        new_haven = Location.where(city_name: STARTING_VILLAGE_NAME).first
        if new_haven
          room = find_best_room_in_location(new_haven.id)
          return room if room
        end

        # Priority 4: Generic fallbacks
        public_filter = Sequel.lit("publicity IS NULL OR publicity = 'public'")
        Room.where(name: 'Village Entrance').first ||
          Room.where(room_type: 'intersection').where(public_filter).first ||
          Room.exclude(id: location.id).where(public_filter).first
      end

      def find_best_room_in_location(location_id)
        # Prefer an intersection (a crossroads feels like a natural entry point)
        Room.where(location_id: location_id, room_type: 'intersection')
            .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
            .first ||
          Room.where(location_id: location_id)
              .where(Sequel.lit("publicity IS NULL OR publicity = 'public'"))
              .first
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::EnterGame)
