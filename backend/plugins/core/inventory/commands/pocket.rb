# frozen_string_literal: true

module Commands
  module Inventory
    class Pocket < Commands::Base::Command
      command_name 'pocket'
      aliases 'stow', 'stash', 'put away', 'sheathe', 'holster'
      category :inventory
      help_text 'Put a held item away or sheathe in a holster'
      usage 'pocket <item>'
      examples 'pocket sword', 'pocket all', 'sheathe dagger'

      protected

      def perform_command(parsed_input)
        target = parsed_input[:text]
        items = held_items

        # No argument - show menu if holding items
        if blank?(target)
          return error_result("You aren't holding anything.") if items.empty?
          return item_selection_menu(items, 'What would you like to put away?', command: 'pocket')
        end

        target = target.strip

        # Handle "pocket all"
        if target.downcase == 'all'
          return pocket_all(items)
        end

        # Pocket specific item
        return error_result("You aren't holding anything.") if items.empty?

        result = resolve_item_with_menu(target, items)

        if result[:disambiguation]
          return disambiguation_result(result[:result], "Which '#{target}' do you want to put away?")
        end

        return error_result(result[:error] || "You aren't holding '#{target}'.") if result[:error]

        pocket_item(result[:match])
      end

      private

      def held_items
        # Items being held (held: true flag)
        character_instance.objects_dataset.where(held: true).all
      end

      def pocket_item(item)
        # Try to find a compatible holster
        holster = find_compatible_holster(item)

        if holster
          sheathe_to_holster(item, holster)
        else
          item.pocket!
          broadcast_to_room("#{character.full_name} puts away #{item.name}.", exclude_character: character_instance)
          success_result(
            "You put away #{item.name}.",
            type: :message,
            data: { action: 'pocket', item_id: item.id, item_name: item.name }
          )
        end
      end

      def sheathe_to_holster(item, holster)
        holster.holster_weapon!(item)
        broadcast_to_room("#{character.full_name} sheathes #{item.name} in #{holster.name}.", exclude_character: character_instance)
        success_result(
          "You sheathe #{item.name} in #{holster.name}.",
          type: :message,
          data: { action: 'pocket', item_id: item.id, item_name: item.name, holster_id: holster.id, holster_name: holster.name }
        )
      end

      def find_compatible_holster(weapon)
        # Find a worn holster that can accept this weapon
        character_instance.worn_items.all.find do |item|
          item.can_holster?(weapon)
        end
      end

      def pocket_all(items)
        return error_result("You aren't holding anything.") if items.empty?

        item_names = items.map(&:name)
        items.each { |item| pocket_item_quietly(item) }

        broadcast_to_room(
          "#{character.full_name} puts away several items.",
          exclude_character: character_instance
        )

        success_result(
          "You put away #{item_names.join(', ')}.",
          type: :message,
          data: { action: 'pocket_all', items: item_names }
        )
      end

      def pocket_item_quietly(item)
        holster = find_compatible_holster(item)

        if holster
          holster.holster_weapon!(item)
          { sheathed: true }
        else
          item.pocket!
          { sheathed: false }
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Pocket)
