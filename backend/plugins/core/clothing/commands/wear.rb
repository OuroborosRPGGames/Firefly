# frozen_string_literal: true

module Commands
  module Clothing
    class Wear < Commands::Base::Command
      command_name 'wear'
      aliases 'don', 'put on'
      category :clothing
      help_text 'Put on clothing or jewelry from your inventory'
      usage 'wear <item> [on <position>] [, item2, item3...]'
      examples 'wear shirt', 'wear gold ring on left ear', 'don jacket', 'wear hat, scarf, gloves'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # Handle piercings specially - they need a position
        # Parse "wear X on Y" pattern for piercings
        if text && text.match?(/\s+on\s+/i)
          return handle_piercing_with_position(text)
        end

        # Standard flow for non-piercings
        # But we need to intercept piercings to show position menu
        items = wearable_items

        return error_result("You don't have anything to wear.") if items.empty?

        # If no input, show menu
        if blank?(text)
          return item_selection_menu(items, 'What would you like to wear?',
                                     command: 'wear',
                                     description_field: ->(item) { item_description(item) })
        end

        # Check if single item is a piercing - needs special handling
        item_names = parse_multi_item_input(text)
        if item_names.length == 1 && !text.include?(',') && !text.match?(/\s+and\s+/i)
          item = TargetResolverService.resolve(
            query: item_names.first,
            candidates: items,
            name_field: :name
          )

          if item&.piercing?
            return handle_piercing_wear(item)
          end
        end

        # Standard multi-item or non-piercing flow
        # Filter out piercings from standard wear (they need position)
        non_piercing_items = items.reject(&:piercing?)

        if non_piercing_items.empty?
          # Only piercings available - show special message
          return error_result("You only have piercings to wear. Use 'wear <piercing> on <position>'.")
        end

        standard_item_command(
          input: text,
          items_getter: -> { non_piercing_items },
          action_method: :wear!,
          action_name: 'wear',
          menu_prompt: 'What would you like to wear?',
          self_verb: 'put on',
          other_verb: 'puts on',
          empty_error: "You don't have anything to wear.",
          not_found_error: "You don't have '%{input}' to wear.",
          description_field: ->(item) { item_description(item) },
          allow_multiple: true
        )
      end

      private

      def wearable_items
        character_instance.inventory_items.all.select do |item|
          (item.clothing? || item.jewelry?) && !item.worn?
        end
      end

      def item_description(item)
        return 'piercing' if item.piercing?

        item.jewelry? ? 'jewelry' : 'clothing'
      end

      def handle_piercing_with_position(text)
        # Parse "wear X on Y"
        parts = text.strip.split(/\s+on\s+/i, 2)
        item_name = parts[0].strip
        position = parts[1]&.strip

        return error_result("Specify a position. Example: wear gold ring on left ear") if blank?(position)

        items = wearable_items
        item = TargetResolverService.resolve(
          query: item_name,
          candidates: items,
          name_field: :name
        )

        return error_result("You don't have '#{item_name}' to wear.") unless item

        unless item.piercing?
          # Non-piercing - just wear it normally, ignore position
          item.wear!
          broadcast_to_room(
            "#{character.full_name} puts on #{item.name}.",
            exclude_character: character_instance
          )
          return success_result(
            "You put on #{item.name}.",
            type: :message,
            data: { action: 'wear', item_id: item.id, item_name: item.name }
          )
        end

        # Piercing - check position
        result = item.wear!(position: position)
        unless result == true
          return error_result(result)
        end

        broadcast_to_room(
          "#{character.full_name} puts #{item.name} in at #{position}.",
          exclude_character: character_instance
        )

        success_result(
          "You put #{item.name} in your #{position} piercing.",
          type: :message,
          data: { action: 'wear', item_id: item.id, item_name: item.name, position: position }
        )
      end

      def handle_piercing_wear(item)
        positions = character_instance.pierced_positions

        if positions.empty?
          return error_result("You don't have any piercing holes. Use 'pierce <position> with <item>' first.")
        end

        if positions.length == 1
          # Only one position - wear there
          result = item.wear!(position: positions.first)
          unless result == true
            return error_result(result)
          end

          broadcast_to_room(
            "#{character.full_name} puts #{item.name} in at #{positions.first}.",
            exclude_character: character_instance
          )

          return success_result(
            "You put #{item.name} in your #{positions.first} piercing.",
            type: :message,
            data: { action: 'wear', item_id: item.id, item_name: item.name, position: positions.first }
          )
        end

        # Multiple positions - show quickmenu
        options = positions.map do |pos|
          existing = character_instance.piercings_at(pos)
          desc = existing.empty? ? 'empty' : "has #{existing.first.name}"
          { key: pos, label: pos.capitalize, description: desc }
        end

        quickmenu_result(
          "Where do you want to wear #{item.name}?",
          options,
          context: { command: 'wear', item_id: item.id, selecting_position: true }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Wear)
