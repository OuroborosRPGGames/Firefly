# frozen_string_literal: true

module Commands
  module Storage
    class Wardrobe < Commands::Base::Command
      command_name 'wardrobe'
      aliases 'closet', 'stash', 'vault', 'retrieve', 'ret', 'fetch', 'transfer', 'ship', 'summon'
      category :inventory
      help_text 'Manage your wardrobe - store, retrieve, and transfer items between locations'
      usage 'wardrobe [store <item>|retrieve <item>|transfer [from <location>]]'
      examples 'wardrobe', 'wardrobe store sword', 'wardrobe retrieve jacket', 'wardrobe transfer from apartment'

      protected

      def perform_command(parsed_input)
        # Check vault access first
        unless location.vault_accessible?(character)
          return error_result("You need to be in your home or a storage facility to access your wardrobe.")
        end

        text = parsed_input[:text]&.strip || ''
        command_used = parsed_input[:command_word]&.downcase

        # Detect alias used
        if %w[store stash].include?(command_used)
          # Strip command prefix
          item_name = text.sub(/^(store|stash)\s*/i, '').strip
          return handle_store(item_name)
        end

        if %w[retrieve ret fetch].include?(command_used)
          item_name = text.sub(/^(retrieve|ret|fetch)\s*/i, '').strip
          return handle_retrieve(item_name)
        end

        if %w[transfer ship summon].include?(command_used)
          args = text.sub(/^(transfer|ship|summon)\s*/i, '').strip
          return handle_transfer(args)
        end

        # Strip command prefix
        text = text.sub(/^(wardrobe|closet|vault)\s*/i, '').strip

        # No args - show wardrobe menu
        return show_wardrobe_menu if text.empty?

        # Parse action
        parts = text.split(/\s+/, 2)
        action = parts[0]&.downcase
        args = parts[1]&.strip

        case action
        when 'store', 'stash', 'put'
          handle_store(args)
        when 'retrieve', 'get', 'take', 'fetch'
          handle_retrieve(args)
        when 'transfer', 'ship', 'move'
          handle_transfer(args)
        when 'status'
          show_transfer_status
        when 'list'
          list_stored_items
        when 'all'
          retrieve_all_items
        else
          # Treat as item name for retrieve
          handle_retrieve(text)
        end
      end

      private

      def show_wardrobe_menu
        # Count items
        stored_here = Item.stored_in_room(character_instance, location).count
        total_stored = Item.stored_items_for(character_instance).count
        other_locations = total_stored - stored_here
        in_transit = Item.in_transit_for(character_instance).count
        inventory = character_instance.objects_dataset.where(stored: false, worn: false, equipped: false).count

        options = [
          { key: 'list', label: 'View Wardrobe', description: "#{stored_here} item#{stored_here == 1 ? '' : 's'} stored here" }
        ]

        if inventory > 0
          options << { key: 'store', label: 'Store Items', description: "Store #{inventory} item#{inventory == 1 ? '' : 's'} from inventory" }
        end

        if stored_here > 0
          options << { key: 'retrieve', label: 'Retrieve Items', description: 'Get items from wardrobe' }
          options << { key: 'retrieve_all', label: 'Retrieve All', description: "Get all #{stored_here} item#{stored_here == 1 ? '' : 's'}" }
        end

        if other_locations > 0
          options << { key: 'transfer', label: 'Transfer Items', description: "#{other_locations} item#{other_locations == 1 ? '' : 's'} at other locations" }
        end

        if in_transit > 0
          options << { key: 'status', label: 'Transfer Status', description: "#{in_transit} item#{in_transit == 1 ? '' : 's'} in transit" }
        end

        options << { key: 'q', label: 'Close', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          "Wardrobe (#{stored_here} here, #{other_locations} elsewhere)",
          options,
          context: { command: 'wardrobe' }
        )
      end

      # ========== Store ==========

      def handle_store(item_name)
        if item_name.nil? || item_name.empty?
          return show_store_menu
        end

        # Handle 'store all' - store all inventory items
        if item_name.downcase == 'all'
          return store_all_items
        end

        # Find item in inventory
        item = find_inventory_item(item_name)

        # If not found among non-stored items, check if it's already stored
        unless item
          stored_item = find_stored_item_here(item_name)
          if stored_item
            return error_result("#{stored_item.name} is already stored.")
          end
          return error_result("You don't have '#{item_name}' in your inventory.")
        end

        if item.worn?
          return error_result("You need to remove #{item.name} first.")
        end

        if item.equipped?
          return error_result("You need to unequip #{item.name} first.")
        end

        # Store the item in current room
        item.store!(location)

        output = "You store #{item.name} in your wardrobe."
        broadcast_to_room("#{character.full_name} stores something in their wardrobe.", exclude_character: character_instance)

        success_result(
          output,
          type: :message,
          data: { action: 'store', item_id: item.id, item_name: item.name }
        )
      end

      def show_store_menu
        items = character_instance.objects_dataset
          .where(stored: false, worn: false, equipped: false)
          .all

        if items.empty?
          return error_result("You have nothing to store. Remove or unequip items first.")
        end

        options = items.each_with_index.map do |item, idx|
          { key: (idx + 1).to_s, label: item.name, description: item.condition || '' }
        end

        options << { key: 'all', label: 'Store All', description: "Store all #{items.count} item#{items.count == 1 ? '' : 's'}" }
        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        item_data = items.map { |i| { id: i.id, name: i.name } }

        create_quickmenu(
          character_instance,
          'Store which item?',
          options,
          context: { command: 'wardrobe_store', items: item_data }
        )
      end

      def store_all_items
        items = character_instance.objects_dataset
          .where(stored: false, worn: false, equipped: false)
          .all

        if items.empty?
          return error_result("You have nothing to store.")
        end

        count = 0
        items.each do |item|
          item.store!(location)
          count += 1
        end

        output = "You store #{count} item(s) in your wardrobe."
        broadcast_to_room("#{character.full_name} stores items in their wardrobe.", exclude_character: character_instance)

        success_result(
          output,
          type: :message,
          data: { action: 'store_all', count: count }
        )
      end

      # ========== Retrieve ==========

      def handle_retrieve(item_name)
        if item_name.nil? || item_name.empty?
          return show_retrieve_menu
        end

        # Handle 'retrieve all'
        if item_name.downcase == 'all'
          return retrieve_all_items
        end

        # Find stored item by name
        item = find_stored_item_here(item_name)
        return error_result("You don't have '#{item_name}' stored in your wardrobe.") unless item

        # Retrieve the item
        item.retrieve!

        output = "You retrieve #{item.name} from your wardrobe."
        broadcast_to_room("#{character.full_name} retrieves something from their wardrobe.", exclude_character: character_instance)

        success_result(
          output,
          type: :message,
          data: { action: 'retrieve', item_id: item.id, item_name: item.name }
        )
      end

      def show_retrieve_menu
        items = Item.stored_in_room(character_instance, location).all

        if items.empty?
          total_stored = Item.stored_items_for(character_instance).count
          if total_stored > 0
            return success_result(
              "Your wardrobe here is empty.\nYou have #{total_stored} item(s) at other locations. Use 'wardrobe transfer' to move them.",
              type: :message,
              data: { action: 'wardrobe', count: 0, items: [], other_locations_count: total_stored }
            )
          end
          return success_result("Your wardrobe is empty.", type: :message, data: { action: 'wardrobe', count: 0, items: [] })
        end

        options = items.each_with_index.map do |item, idx|
          { key: (idx + 1).to_s, label: item.name, description: item.condition || '' }
        end

        options << { key: 'all', label: 'Retrieve All', description: "Get all #{items.count} item#{items.count == 1 ? '' : 's'}" }
        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        item_data = items.map { |i| { id: i.id, name: i.name } }

        create_quickmenu(
          character_instance,
          "Retrieve which item? (#{items.count} stored)",
          options,
          context: { command: 'wardrobe_retrieve', items: item_data }
        )
      end

      def list_stored_items
        items = Item.stored_in_room(character_instance, location).all

        if items.empty?
          total_stored = Item.stored_items_for(character_instance).count
          if total_stored > 0
            return success_result(
              "Your wardrobe here is empty.\nYou have #{total_stored} item(s) at other locations. Use 'wardrobe transfer' to move them.",
              type: :message,
              data: { action: 'wardrobe', count: 0, items: [], other_locations_count: total_stored }
            )
          end
          return success_result("Your wardrobe is empty.", type: :message, data: { action: 'wardrobe', count: 0, items: [] })
        end

        lines = ["Your Wardrobe Here (#{items.count} item#{'s' if items.count != 1}):"]
        lines << "=" * 40
        lines << ""
        items.each { |item| lines << "  #{item.name}" }
        lines << ""
        lines << "Use 'wardrobe retrieve <item>' to get an item."
        lines << "Use 'wardrobe transfer' to see items at other locations."

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'wardrobe', count: items.count, items: items.map { |i| { id: i.id, name: i.name } } }
        )
      end

      def retrieve_all_items
        items = Item.stored_in_room(character_instance, location).all

        if items.empty?
          return error_result("Your wardrobe here is empty. Use 'wardrobe transfer' to move items from other locations.")
        end

        count = 0
        items.each do |item|
          item.retrieve!
          count += 1
        end

        output = "You retrieve #{count} item(s) from your wardrobe."
        broadcast_to_room("#{character.full_name} retrieves items from their wardrobe.", exclude_character: character_instance)

        success_result(
          output,
          type: :message,
          data: { action: 'retrieve_all', count: count }
        )
      end

      # ========== Transfer ==========

      def handle_transfer(args)
        if args.nil? || args.empty?
          return list_transfer_locations
        end

        if args.downcase == 'status'
          return show_transfer_status
        end

        # 'transfer from <location>': initiate transfer
        if args.downcase.start_with?('from ')
          location_name = args.sub(/^from\s+/i, '')
          return initiate_transfer(location_name)
        end

        # Try to interpret as location name
        initiate_transfer(args)
      end

      def list_transfer_locations
        # Find all rooms where character has stored items (excluding current room)
        room_ids = Item.where(character_instance_id: character_instance.id, stored: true)
                       .exclude(stored_room_id: nil)
                       .exclude(stored_room_id: location.id)
                       .where(transfer_started_at: nil)
                       .select_map(:stored_room_id)
                       .uniq

        if room_ids.empty?
          return success_result(
            "You have no items stored at other locations.",
            type: :message,
            data: { action: 'transfer_list', locations: [] }
          )
        end

        options = []
        locations_data = []

        room_ids.each_with_index do |room_id, idx|
          room = Room[room_id]
          next unless room

          count = Item.stored_in_room(character_instance, room).count
          options << { key: (idx + 1).to_s, label: room.name, description: "#{count} item#{count == 1 ? '' : 's'}" }
          locations_data << { room_id: room_id, room_name: room.name, count: count }
        end

        options << { key: 'status', label: 'Check Status', description: 'View transfers in progress' }
        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        create_quickmenu(
          character_instance,
          'Transfer from which location? (12-hour delay)',
          options,
          context: { command: 'wardrobe_transfer', locations: locations_data }
        )
      end

      def show_transfer_status
        in_transit = Item.in_transit_for(character_instance).all

        if in_transit.empty?
          return success_result(
            "No transfers in progress.",
            type: :message,
            data: { action: 'transfer_status', completed: [], pending: [] }
          )
        end

        # Check for completed transfers and complete them
        completed = []
        pending = []

        in_transit.each do |item|
          if item.transfer_ready?
            item.complete_transfer!
            completed << item
          else
            pending << item
          end
        end

        lines = []

        if completed.any?
          lines << "Transfers Completed (#{completed.count} item(s) now available):"
          completed.each { |i| lines << "  * #{i.name}" }
          lines << ""
        end

        if pending.any?
          lines << "Transfers In Progress:"
          pending.group_by(&:transfer_destination_room_id).each do |room_id, items|
            room = Room[room_id]
            time_left = items.first.time_until_transfer_ready
            hours = (time_left / 3600).floor
            minutes = ((time_left % 3600) / 60).floor
            lines << "  To #{room&.name || 'Unknown'}: #{items.count} item(s) - #{hours}h #{minutes}m remaining"
          end
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'transfer_status',
            completed: completed.map { |i| { id: i.id, name: i.name } },
            pending: pending.map { |i| { id: i.id, name: i.name, time_remaining: i.time_until_transfer_ready } }
          }
        )
      end

      def initiate_transfer(location_name)
        # Find the source room by name match
        room_ids = Item.where(character_instance_id: character_instance.id, stored: true)
                       .exclude(stored_room_id: nil)
                       .exclude(stored_room_id: location.id)
                       .where(transfer_started_at: nil)
                       .select_map(:stored_room_id)
                       .uniq

        source_room = nil
        room_ids.each do |room_id|
          room = Room[room_id]
          if room && room.name.downcase.include?(location_name.downcase)
            source_room = room
            break
          end
        end

        unless source_room
          return error_result("No items found at location matching '#{location_name}'.")
        end

        items = Item.stored_in_room(character_instance, source_room).all

        if items.empty?
          return error_result("No items to transfer from #{source_room.name}.")
        end

        # Start transfer for all items
        items.each { |item| item.start_transfer!(location) }

        output = "Transfer initiated: #{items.count} item(s) from #{source_room.name}.\n"
        output += "Items will be available here in 12 hours.\n"
        output += "Use 'wardrobe status' to check progress."

        broadcast_to_room("#{character.full_name} arranges for items to be transferred.",
                          exclude_character: character_instance)

        success_result(
          output,
          type: :message,
          data: {
            action: 'transfer_initiated',
            source_room: source_room.name,
            item_count: items.count,
            hours_until_ready: 12
          }
        )
      end

      # ========== Helpers ==========

      def find_inventory_item(name)
        character_instance.objects_dataset
          .where(stored: false)
          .where { Sequel.ilike(:name, "%#{name}%") }
          .first
      end

      def find_stored_item_here(name)
        Item.stored_in_room(character_instance, location)
            .where { Sequel.ilike(:name, "%#{name}%") }
            .first
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Storage::Wardrobe)
