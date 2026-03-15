# frozen_string_literal: true

module Commands
  module Inventory
    class Give < Commands::Base::Command
      command_name 'give'
      aliases 'hand', 'offer', 'throw', 'toss', 'pass', 'slip', 'gift'
      category :inventory
      help_text 'Give items or money to another character'
      usage 'give <item> to <character> | give <amount> to <character>'
      examples 'give sword to John', 'give 100 to Alice', 'give potion to Bob'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        if blank?(text)
          return show_give_item_menu
        end

        # Parse "X to Y" format
        parsed = parse_give_input(text.strip)

        # Fall back to normalizer for "bob sword", "bob the sword" patterns
        unless parsed
          normalized = parsed_input[:normalized]
          if normalized[:target] && normalized[:item]
            # Context-aware: check which word is a character in the room
            if find_character_by_name(normalized[:target])
              parsed = [normalized[:item], normalized[:target]]
            elsif find_character_by_name(normalized[:item])
              parsed = [normalized[:target], normalized[:item]]
            else
              parsed = [normalized[:item], normalized[:target]]
            end
          end
        end

        return error_result("Give what to whom? Use: give <item> to <character>") unless parsed

        item_or_amount, target_name = parsed

        target_char = find_character_by_name(target_name)
        return error_result("You don't see '#{target_name}' here.") unless target_char

        target_instance = find_character_instance_in_room(target_char)
        return error_result("#{target_char.full_name} isn't here.") unless target_instance

        error = prevent_self_target(target_instance, "give things to")
        return error if error

        if money_reference?(item_or_amount, include_keywords: false) # only numbers, not keywords like "money"
          give_money(item_or_amount, target_instance)
        else
          give_item(item_or_amount, target_instance)
        end
      end

      private

      # Show a quickmenu of inventory items to give
      def show_give_item_menu
        items = character_instance.inventory_items.all
        return error_result("You aren't carrying anything to give.") if items.empty?

        # Check if anyone to give to
        others = location.character_instances_dataset.exclude(id: character_instance.id).all
        return error_result("There's no one here to give things to.") if others.empty?

        # Use ItemMenuHelper for standardized menu building
        custom_selection_menu(
          items,
          "What would you like to give?",
          command: 'give',
          label_proc: ->(item) { item.quantity > 1 ? "(x#{item.quantity}) #{item.name}" : item.name },
          description_proc: ->(item) { item.held? ? 'held' : 'carried' },
          data_proc: ->(item) { { id: item.id, name: plain_name(item.name) } }
        )
      end

      # Show a quickmenu of characters in room to give to
      def show_give_target_menu(item_id, item_name)
        others = location.character_instances_dataset
                         .exclude(id: character_instance.id)
                         .all

        if others.empty?
          return error_result("There's no one here to give things to.")
        end

        options = others.each_with_index.map do |ci, idx|
          {
            key: (idx + 1).to_s,
            label: ci.character.full_name,
            description: ci.character.short_desc || ''
          }
        end

        options << { key: 'q', label: 'Cancel', description: 'Close menu' }

        # Store character data for matching
        char_data = others.map do |ci|
          { id: ci.id, name: ci.character.forename }
        end

        create_quickmenu(
          character_instance,
          "Give #{item_name} to whom?",
          options,
          context: {
            command: 'give',
            stage: 'select_target',
            item_id: item_id,
            item_name: item_name,
            characters: char_data
          }
        )
      end

      def parse_give_input(text)
        # Patterns: "sword to John", "100 to Alice"
        if match = text.match(/^(.+?)\s+to\s+(.+)$/i)
          [match[1].strip, match[2].strip]
        else
          nil
        end
      end

      # Note: money_reference? removed - use version from base command (with include_keywords: false)

      # Uses inherited find_character_instance_in_room from base command

      def give_item(item_name, target_instance)
        item = find_item_in_inventory(item_name)
        return error_result("You don't have '#{item_name}'.") unless item

        target_name = target_instance.character.full_name
        item.move_to_character(target_instance)

        # Messages
        self_msg = "You give #{item.name} to #{target_name}."
        target_msg = "#{character.full_name} gives you #{item.name}."
        room_msg = "#{character.full_name} gives #{item.name} to #{target_name}."

        send_to_character(target_instance, target_msg)
        broadcast_to_room(room_msg, exclude_character: character_instance)

        success_result(
          self_msg,
          type: :message,
          data: {
            action: 'give',
            item_id: item.id,
            item_name: item.name,
            recipient_id: target_instance.character.id,
            recipient_name: target_name
          }
        )
      end

      def give_money(amount_text, target_instance)
        amount = amount_text.to_i
        return error_result("Invalid amount.") if amount <= 0

        currency = default_currency
        return error_result("No currency defined.") unless currency

        # Use base class helper for sender's wallet
        my_wallet = wallet_for(currency)
        return error_result("You don't have any money.") unless my_wallet
        return error_result("You don't have that much money.") if my_wallet.balance < amount

        # For target, need custom logic since it's a different character
        target_wallet = find_or_create_wallet_for(target_instance, currency)
        return error_result("#{target_instance.character.full_name} can't accept money.") unless target_wallet

        success = my_wallet.transfer_to(target_wallet, amount)
        return error_result("Transfer failed.") unless success

        formatted_amount = currency.format_amount(amount)
        target_name = target_instance.character.full_name

        self_msg = "You give #{formatted_amount} to #{target_name}."
        target_msg = "#{character.full_name} gives you #{formatted_amount}."
        room_msg = "#{character.full_name} gives #{formatted_amount} to #{target_name}."

        send_to_character(target_instance, target_msg)
        broadcast_to_room(room_msg, exclude_character: character_instance)

        success_result(
          self_msg,
          type: :message,
          data: {
            action: 'give_money',
            amount: amount,
            currency: currency.name,
            recipient_id: target_instance.character.id,
            recipient_name: target_name
          }
        )
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Inventory::Give)
