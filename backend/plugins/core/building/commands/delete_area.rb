# frozen_string_literal: true

module Commands
  module Building
    class DeleteZone < Commands::Base::Command
      command_name 'delete zone'
      aliases 'remove zone', 'delete area', 'remove area'
      category :building
      help_text 'Delete a zone and all its contents (admin only)'
      usage 'delete zone <name>'
      examples 'delete zone Old Slums'

      protected

      def perform_command(parsed_input)
        error = require_admin(error_message: "Only administrators can delete zones.")
        return error if error

        zone_name = (parsed_input[:text] || '').sub(/^(zone|area)\s*/i, '').strip

        if zone_name.empty?
          return error_result("Which zone do you want to delete? Usage: delete zone <name>")
        end

        # Find the zone
        zone = Zone.where(Sequel.ilike(:name, zone_name)).first

        unless zone
          return error_result("No zone found matching '#{zone_name}'.")
        end

        # Prevent deleting the zone you're currently in
        current_zone = location.location&.zone
        if current_zone&.id == zone.id
          return error_result("You cannot delete the zone you are currently in. Move to a different zone first.")
        end

        # Get all location IDs for this zone in one query
        location_ids = zone.locations_dataset.select_map(:id)

        # Find spawn room or any other safe room outside this zone
        spawn_room = Room.tutorial_spawn_room
        # If the spawn room is in the zone being deleted, find another room
        if spawn_room && location_ids.include?(spawn_room.location_id)
          spawn_room = Room.exclude(location_id: location_ids).first
        end

        unless spawn_room
          return error_result("Cannot find a safe spawn room to relocate characters. Please create a spawn room first.")
        end

        # Get all room IDs in this zone (single query)
        room_ids = Room.where(location_id: location_ids).select_map(:id)

        # Find all characters in these rooms (single query)
        characters_to_move = CharacterInstance.where(current_room_id: room_ids).all

        # Get online character IDs for notification
        online_character_ids = characters_to_move.select(&:online).map(&:id)

        # Batch update all characters to spawn room (single query)
        if characters_to_move.any?
          CharacterInstance.where(current_room_id: room_ids).update(
            current_room_id: spawn_room.id,
            x: 0.0,
            y: 0.0,
            z: 0.0
          )
        end

        # Notify online characters
        online_character_ids.each do |ci_id|
          BroadcastService.to_character(
            ci_id,
            "The zone '#{zone.name}' has been deleted. You have been moved to #{spawn_room.name}.",
            type: :message
          )
        end

        zone_id = zone.id
        zone_display_name = zone.name
        location_count = location_ids.length
        room_count = room_ids.length

        # Bulk delete room contents (instead of N cleanup_contents! calls)
        if room_ids.any?
          Decoration.where(room_id: room_ids).delete
          Graffiti.where(room_id: room_ids).delete
          Place.where(room_id: room_ids).delete
          # NOTE: RoomExit model was removed - navigation now uses spatial adjacency
          RoomFeature.where(room_id: room_ids).delete if defined?(RoomFeature)
          RoomUnlock.where(room_id: room_ids).delete if defined?(RoomUnlock)
          UnifiedObject.where(room_id: room_ids).delete if defined?(UnifiedObject)

          # Delete shops and their items
          shop_ids = Shop.where(room_id: room_ids).select_map(:id)
          if shop_ids.any?
            ShopItem.where(shop_id: shop_ids).delete
            Shop.where(id: shop_ids).delete
          end

          # Delete rooms
          Room.where(id: room_ids).delete
        end

        # Delete location associations and locations
        if location_ids.any?
          Weather.where(location_id: location_ids).delete
          Location.where(id: location_ids).delete
        end

        # Delete the zone
        zone.delete

        success_result(
          "Deleted zone '#{zone_display_name}' including #{location_count} locations and #{room_count} rooms. " \
          "#{characters_to_move.length} character(s) were relocated to spawn.",
          type: :message,
          data: {
            action: 'delete_zone',
            zone_id: zone_id,
            zone_name: zone_display_name,
            locations_deleted: location_count,
            rooms_deleted: room_count,
            characters_relocated: characters_to_move.length
          }
        )
      end
    end

    # Backward compatibility alias
    DeleteArea = DeleteZone
  end
end

Commands::Base::Registry.register(Commands::Building::DeleteZone)
