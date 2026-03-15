# frozen_string_literal: true

# CommandDisambiguationHandler processes responses to disambiguation quickmenus.
#
# When a command returns multiple matches (e.g., 2 swords for "get sword"),
# a quickmenu is shown. When the user selects an option, this handler
# completes the original command with the selected target.
#
# The context stored in the quickmenu includes:
# - action: the command that created the menu (e.g., 'get', 'drop', 'follow')
# - match_ids: array of candidate IDs
# - any command-specific context (e.g., shop_id for buy)
#
class CommandDisambiguationHandler
  # Action configurations for item commands that follow the same pattern
  ITEM_ACTIONS = {
    'get' => {
      method: ->(item, char) { item.move_to_character(char) },
      self_verb: 'pick up',
      other_verb: 'picks up'
    },
    'drop' => {
      method: ->(item, char) { item.move_to_room(Room[char.current_room_id]) },
      self_verb: 'drop',
      other_verb: 'drops'
    },
    'wear' => {
      method: ->(item, _char, context) {
        if item.piercing?
          position = context[:position] || context['position']
          return { error: 'Piercings require a body position.' } unless position

          result = item.wear!(position: position)
          return { error: result } if result.is_a?(String)
        else
          item.wear!
        end
        nil
      },
      self_verb: 'put on',
      other_verb: 'puts on'
    },
    'remove' => {
      method: ->(item, char) { item.remove!(char) },
      self_verb: 'remove',
      other_verb: 'removes'
    },
    'hold' => {
      method: ->(item, char) { item.hold!(char) },
      self_verb: 'hold',
      other_verb: 'holds'
    },
    'pocket' => {
      method: ->(item, char) { item.pocket!(char) },
      self_verb: 'pocket',
      other_verb: 'pockets'
    },
    'eat' => {
      method: ->(item, char) { item.consume!(char) },
      self_verb: 'eat',
      other_verb: 'eats',
      no_broadcast: true
    },
    'drink' => {
      method: ->(item, char) { item.consume!(char) },
      self_verb: 'drink',
      other_verb: 'drinks',
      no_broadcast: true
    },
    'smoke' => {
      method: ->(item, char) { item.consume!(char) },
      self_verb: 'smoke',
      other_verb: 'smokes',
      no_broadcast: true
    }
  }.freeze

  class << self
    include HandlerResponseHelper
    include PersonalizedBroadcastConcern

    def process_response(char_instance, interaction_data, selected_key)
      context = interaction_data[:context] || interaction_data['context'] || {}
      action = context[:action] || context['action']
      match_ids = context[:match_ids] || context['match_ids'] || []

      # Get the selected ID from match_ids array (1-indexed key)
      selected_index = selected_key.to_i - 1
      selected_id = match_ids[selected_index]

      return error_response("Invalid selection") unless selected_id

      # Check if this is a standard item action
      if ITEM_ACTIONS.key?(action)
        complete_item_action(char_instance, selected_id, action, context)
      else
        # Dispatch to specialized handlers
        case action
        when 'buy'
          complete_buy(char_instance, selected_id, context)
        when 'preview'
          complete_preview(char_instance, selected_id, context)
        when 'follow'
          complete_follow(char_instance, selected_id, context)
        when 'lead'
          complete_lead(char_instance, selected_id, context)
        when 'whisper'
          complete_whisper(char_instance, selected_id, context)
        when 'show'
          complete_show(char_instance, selected_id, context)
        when 'give'
          complete_give(char_instance, selected_id, context)
        when 'fabricate_deck'
          complete_fabricate_deck(char_instance, selected_id, context)
        else
          error_response("Unknown action: #{action}")
        end
      end
    end

    private

    # ====== GENERIC ITEM ACTION HANDLER ======

    def complete_item_action(char_instance, item_id, action, context)
      config = ITEM_ACTIONS[action]

      with_record(Item, item_id) do |item|
        # Some actions have additional validation
        if action == 'wear' && !item.wearable?
          return error_response("#{item.name} is not wearable.")
        end

        # Execute the action
        action_result = if config[:method].arity == 3
                          config[:method].call(item, char_instance, context)
                        else
                          config[:method].call(item, char_instance)
                        end

        # Check for errors from complex actions (like wear with piercings)
        return error_response(action_result[:error]) if action_result.is_a?(Hash) && action_result[:error]

        # Broadcast to room unless suppressed
        unless config[:no_broadcast]
          broadcast_personalized_to_room(
            char_instance.current_room_id,
            "#{char_instance.character.full_name} #{config[:other_verb]} #{item.name}.",
            exclude: [char_instance.id],
            extra_characters: [char_instance]
          )
        end

        success_response(
          "You #{config[:self_verb]} #{item.name}.",
          action: action,
          item_id: item.id
        )
      end
    end

    # ====== SHOP COMMANDS ======

    def complete_buy(char_instance, item_id, context)
      shop_id = context[:shop_id] || context['shop_id']
      shop = Shop[shop_id] if shop_id

      stock_item = shop&.stock_items_dataset&.first(id: item_id)
      return error_response("Item not found in shop") unless stock_item

      currency = shop.currency || Currency.default_for(shop.location.zone.world.universe)
      wallet = char_instance.wallets_dataset.first(currency_id: currency.id)
      balance = wallet&.balance || 0

      return error_response("You can't afford #{stock_item.name}.") if balance < stock_item.price

      wallet.subtract(stock_item.price)
      new_item = stock_item.create_item_for(char_instance)

      success_response(
        "You buy #{new_item.name} for #{currency.format_amount(stock_item.price)}.",
        action: 'buy',
        item_id: new_item.id,
        price: stock_item.price
      )
    end

    def complete_preview(char_instance, item_id, context)
      shop_id = context[:shop_id] || context['shop_id']
      shop = Shop[shop_id] if shop_id

      stock_item = shop&.stock_items_dataset&.first(id: item_id)
      return error_response("Item not found in shop") unless stock_item

      success_response(
        "#{stock_item.name}\n#{stock_item.description}",
        action: 'preview',
        item_id: stock_item.id,
        name: stock_item.name,
        description: stock_item.description
      )
    end

    # ====== ITEM DISPLAY COMMANDS ======

    def complete_show(char_instance, item_id, _context)
      with_record(Item, item_id) do |item|
        success_response(
          "You show #{item.name}.\n#{item.description}",
          action: 'show',
          item_id: item.id,
          name: item.name,
          description: item.description
        )
      end
    end

    def complete_give(char_instance, selected_id, context)
      step = context[:step] || context['step'] || 'item'

      if step == 'item'
        with_record(Item, selected_id) do |item|
          target_id = context[:target_id] || context['target_id']
          if target_id
            target = CharacterInstance[target_id]
            return complete_give_action(char_instance, item, target)
          end

          error_response("No target specified for give command")
        end
      else
        item_id = context[:item_id] || context['item_id']
        item = Item[item_id]
        target = CharacterInstance[selected_id]

        return error_response("Item not found") unless item
        return error_response("Target not found") unless target

        complete_give_action(char_instance, item, target)
      end
    end

    def complete_give_action(char_instance, item, target)
      item.move_to_character(target)

      broadcast_personalized_to_room(
        char_instance.current_room_id,
        "#{char_instance.character.full_name} gives #{item.name} to #{target.character.full_name}.",
        exclude: [char_instance.id],
        extra_characters: [char_instance, target]
      )

      giver_name = char_instance.character.display_name_for(target)
      BroadcastService.to_character(
        target,
        "#{giver_name} gives you #{item.name}."
      )

      success_response(
        "You give #{item.name} to #{target.character.full_name}.",
        action: 'give',
        item_id: item.id,
        target_id: target.id
      )
    end

    # ====== CHARACTER COMMANDS ======

    def complete_follow(char_instance, target_id, _context)
      with_record(CharacterInstance, target_id, error_message: "Character not found") do |target|
        result = MovementService.start_following(char_instance, target)
        result_to_response(result, action: 'follow', target_id: target.id)
      end
    end

    def complete_lead(char_instance, target_id, _context)
      with_record(CharacterInstance, target_id, error_message: "Character not found") do |target|
        result = MovementService.grant_follow_permission(char_instance, target)
        result_to_response(result, action: 'lead', target_id: target.id)
      end
    end

    def complete_whisper(char_instance, target_id, context)
      with_record(CharacterInstance, target_id, error_message: "Character not found") do |target|
        message = context[:message] || context['message']
        return error_response("No message to whisper") if message.nil? || message.empty?

        whisperer_name = char_instance.character.display_name_for(target)
        BroadcastService.to_character(
          target,
          "#{whisperer_name} whispers to you: #{message}"
        )

        success_response(
          "You whisper to #{target.character.full_name}: #{message}",
          action: 'whisper',
          target_id: target.id
        )
      end
    end

    # ====== CRAFTING COMMANDS ======

    def complete_fabricate_deck(char_instance, pattern_id, _context)
      with_record(DeckPattern, pattern_id, error_message: "Deck pattern not found") do |pattern|
        character = char_instance.character
        has_access = pattern.creator_id == character.id ||
                     pattern.is_public ||
                     DeckOwnership.where(character_id: character.id, deck_pattern_id: pattern.id).any?

        return error_response("You don't have access to that deck pattern.") unless has_access

        deck = pattern.create_deck_for(char_instance)

        success_response(
          "You conjure #{pattern.name} with #{deck.remaining_count} cards.",
          action: 'fabricate_deck',
          deck_id: deck.id,
          pattern_id: pattern.id,
          pattern_name: pattern.name,
          card_count: deck.remaining_count
        )
      end
    end
  end
end
