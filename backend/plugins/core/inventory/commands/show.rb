# frozen_string_literal: true

module Commands
  module Inventory
    class Show < Commands::Base::Command
      command_name 'show'
      aliases 'display', 'present'
      category :inventory
      help_text 'Show an item to another character'
      usage 'show <item> to <character>'
      examples 'show sword to Bob', 'show ring to Alice'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # Show quickmenu if no arguments
        if blank?(text)
          return show_item_selection_menu
        end

        text = text.strip

        # Parse "item to person" format
        parts = text.split(/\s+to\s+/i, 2)
        if parts.length < 2
          # Fall back to normalizer for "bob sword", "bob the sword" patterns
          # Context-aware: check which word is a character in the room
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:item]
            if find_character_by_name(normalized[:target])
              item_name = normalized[:item].strip
              target_name = normalized[:target].strip
            elsif find_character_by_name(normalized[:item])
              item_name = normalized[:target].strip
              target_name = normalized[:item].strip
            else
              item_name = normalized[:item].strip
              target_name = normalized[:target].strip
            end
          else
            return error_result("Show what to whom? (show <item> to <person>)")
          end
        else
          item_name = parts[0].strip
          target_name = parts[1].strip
        end

        # Find item in inventory (prefer held items)
        item = find_item_in_inventory(item_name)
        return error_result("You don't have '#{item_name}'.") unless item

        # Find target character in room (uses base command method)
        target_char = find_character_by_name(target_name)
        return error_result("You don't see '#{target_name}' here.") unless target_char

        target_instance = find_character_instance_in_room(target_char)
        return error_result("#{target_char.full_name} isn't here.") unless target_instance

        # Can't show to self
        if target_instance.id == character_instance.id
          return error_result("You can't show something to yourself.")
        end

        target_name_display = target_char.full_name

        # Build description of item
        item_desc = build_item_description(item)

        # Notify the target
        send_to_character(
          target_instance,
          "#{character.full_name} shows you #{item.name}:\n#{item_desc}"
        )

        # Broadcast to others in the room (sender and target are already notified directly)
        broadcast_to_room_except(
          [character_instance, target_instance],
          "#{character.full_name} shows something to #{target_name_display}."
        )

        success_result(
          "You show #{item.name} to #{target_name_display}.",
          type: :message,
          data: {
            action: 'show',
            item_id: item.id,
            item_name: item.name,
            target_id: target_instance.id,
            target_name: target_name_display
          }
        )
      end

      private

      # Show a quickmenu of inventory items to show
      def show_item_selection_menu
        items = character_instance.inventory_items.all
        return error_result("You aren't carrying anything to show.") if items.empty?

        # Check if anyone to show to
        others = location.character_instances_dataset.exclude(id: character_instance.id).all
        return error_result("There's no one here to show things to.") if others.empty?

        # Use ItemMenuHelper for standardized menu building
        custom_selection_menu(
          items,
          "What would you like to show?",
          command: 'show',
          label_proc: ->(item) { item.quantity > 1 ? "(x#{item.quantity}) #{item.name}" : item.name },
          description_proc: ->(item) { item.held? ? 'held' : 'carried' },
          data_proc: ->(item) { { id: item.id, name: plain_name(item.name) } }
        )
      end

      # Uses inherited find_item_in_inventory from base command
      # Uses inherited find_character_instance_in_room from base command
      # Uses inherited find_character_in_room from base command

      def build_item_description(item)
        parts = []
        parts << (item.description || item.name)

        if item.quantity > 1
          parts << "Quantity: #{item.quantity}"
        end

        if item.condition != 'good'
          parts << "Condition: #{item.condition}"
        end

        if item.torn?
          damage = case item.torn
                   when 1..3 then 'slightly damaged'
                   when 4..6 then 'damaged'
                   when 7..9 then 'heavily damaged'
                   else 'destroyed'
                   end
          parts << "Damage: #{damage}"
        end

        parts.join("\n")
      end

      # Uses inherited send_to_character from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Show)
