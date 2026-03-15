# frozen_string_literal: true

module Commands
  module Building
    class BuildShop < Commands::Base::Command
      command_name 'build shop'
      aliases 'create shop'
      category :building
      help_text 'Create a shop in the current room'
      usage 'build shop [shop name]'
      examples 'build shop', 'build shop My General Store'

      protected

      def perform_command(parsed_input)
        room = location
        outer_room = room.outer_room

        # Check ownership
        unless outer_room.owned_by?(character_instance.character)
          return error_result("You don't own this room. You can only create shops in rooms you own.")
        end

        # Check if room already has a shop
        if room.shop
          return error_result("This room already has a shop: #{room.shop.display_name || 'Unnamed Shop'}")
        end

        # Parse shop name
        shop_name = (parsed_input[:text] || '').sub(/^shop\s*/i, '').strip
        shop_name = nil if shop_name.empty?

        if shop_name && shop_name.length > 100
          return error_result('Shop name must be 100 characters or less.')
        end

        # Create the shop
        shop = Shop.create(
          room_id: room.id,
          name: shop_name,
          shopkeeper_name: 'Shopkeeper',
          free_items: false
        )

        # Update room type to shop if not already
        room.update(room_type: 'shop') unless room.room_type == 'shop'

        actor_name = character.full_name
        shop_display_name = shop_name || 'a shop'

        BroadcastService.to_room(
          room.id,
          "#{actor_name} has established #{shop_display_name} here.",
          exclude: [character_instance.id],
          type: :message
        )

        success_result(
          "You establish #{shop_display_name} in this room. Use 'add stock' to add items for sale.",
          type: :message,
          data: {
            action: 'build_shop',
            shop_id: shop.id,
            shop_name: shop_name,
            room_id: room.id
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::BuildShop)
