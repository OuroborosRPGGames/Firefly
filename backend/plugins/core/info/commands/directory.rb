# frozen_string_literal: true

module Commands
  module Info
    class Directory < Commands::Base::Command
      command_name 'directory'
      aliases 'businesses', 'shops', 'yellowpages'
      category :info
      help_text 'View the business directory for this area'
      usage 'directory [category]'
      examples 'directory', 'directory food', 'directory clothing'

      protected

      def perform_command(parsed_input)
        zone = location.location&.zone
        return error_result("You're not in a defined zone.") unless zone

        # Check if in a city or town (or allow all areas with shops)
        category_filter = parsed_input[:text]&.strip&.downcase
        category_filter = nil if category_filter&.empty?

        shops = find_shops_in_zone(zone)

        if shops.empty?
          return error_result("No businesses listed in #{zone.name}.")
        end

        format_directory(zone, shops, category_filter)
      end

      private

      def find_shops_in_zone(zone)
        # Get all rooms in this zone via their locations
        room_ids = Room.join(:locations, id: :location_id)
                       .where(Sequel[:locations][:zone_id] => zone.id)
                       .select_map(Sequel[:rooms][:id])

        return [] if room_ids.empty?

        # Get all shops in those rooms
        Shop.where(room_id: room_ids).eager(:room).all
      end

      def format_directory(zone, shops, category_filter)
        lines = ["<h4>Business Directory - #{zone.name}</h4>"]

        # Group shops by their room's location name
        by_location = shops.group_by do |shop|
          shop.room&.location&.name || 'Unknown'
        end

        by_location.keys.sort.each do |loc_name|
          lines << "#{loc_name}:"
          by_location[loc_name].each do |shop|
            shop_name = shop.display_name || 'Unnamed Shop'
            room_name = shop.room&.name || 'Unknown Room'
            lines << "  #{shop_name} (#{room_name})"
          end
          lines << ""
        end

        lines << "#{shops.length} business(es) listed."
        lines << "Visit a shop and use 'list' to see their goods."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'directory',
            zone_id: zone.id,
            zone_name: zone.name,
            count: shops.length,
            businesses: shops.map { |s| shop_data(s) }
          }
        )
      end

      def shop_data(shop)
        {
          id: shop.id,
          name: shop.display_name,
          room_id: shop.room_id,
          room_name: shop.room&.name,
          location_name: shop.room&.location&.name
        }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Directory)
