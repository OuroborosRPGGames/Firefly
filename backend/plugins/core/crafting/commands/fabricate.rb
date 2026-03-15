# frozen_string_literal: true

module Commands
  module Crafting
    class Fabricate < Commands::Base::Command
      command_name 'fabricate'
      aliases 'conjure', 'fab'
      category :crafting
      help_text 'Create items from patterns you own using appropriate facilities'
      usage 'fabricate <pattern> | fabricate deck | fabricate [orders] | fabricate pickup <id>'
      examples 'fabricate silk dress', 'fabricate leather jacket', 'fabricate deck', 'fabricate', 'fabricate pickup 1'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # No argument = show pending orders
        return show_pending_orders if blank?(text)

        item_name = text.strip.downcase

        # Subcommands
        case item_name
        when 'orders'
          return show_pending_orders
        when /^pickup\s+(\d+)$/i
          return pickup_order(::Regexp.last_match(1).to_i)
        when 'deck'
          return fabricate_deck
        end

        # Check facility access
        unless FabricationService.can_fabricate_here?(character_instance, nil)
          return error_result(no_facility_message)
        end

        # Find matching pattern in inventory
        pattern = find_owned_pattern(item_name)
        return error_result("You don't have a pattern for '#{text.strip}'.") unless pattern

        # Now check if this specific pattern can be fabricated here
        unless FabricationService.can_fabricate_here?(character_instance, pattern)
          return error_result(wrong_facility_message(pattern))
        end

        # Check if fabrication is instant
        if FabricationService.instant?(pattern)
          return fabricate_instantly(pattern)
        end

        # Non-instant: show delivery options quickmenu
        show_delivery_options(pattern)
      end

      private

      # Show pending fabrication orders for the character
      def show_pending_orders
        orders = FabricationService.pending_orders(character_instance.character)

        if orders.empty?
          return success_result(
            "You have no pending fabrication orders.",
            type: :fabrication_orders,
            data: { orders: [] }
          )
        end

        order_data = orders.map.with_index do |order, idx|
          {
            id: order.id,
            index: idx + 1,
            pattern_name: order.pattern&.description || 'Unknown item',
            status: order.status,
            time_remaining: order.time_remaining_display,
            delivery_method: order.delivery_method,
            location: order.delivery? ? order.delivery_room&.name : order.fabrication_room&.name,
            ready: order.ready? || order.complete?
          }
        end

        # Build text display
        lines = ["Pending Orders:"]
        order_data.each do |o|
          status_text = o[:ready] ? "<strong>Ready</strong>" : "Ready in #{o[:time_remaining]}"
          location_text = o[:delivery_method] == 'delivery' ? "delivery to #{o[:location]}" : "pickup at #{o[:location]}"
          lines << "#{o[:index]}. #{o[:pattern_name]} - #{status_text} (#{location_text})"
        end

        success_result(
          lines.join("\n"),
          type: :fabrication_orders,
          data: { orders: order_data }
        )
      end

      # Pick up a ready order by index or ID
      def pickup_order(order_identifier)
        orders = FabricationService.pending_orders(character_instance.character)

        # Try to find by index first (1-based), then by ID
        order = if order_identifier <= orders.count
          orders[order_identifier - 1]
        else
          orders.find { |o| o.id == order_identifier }
        end

        unless order
          return error_result("Order ##{order_identifier} not found.")
        end

        unless order.pickup?
          return error_result("That order is set for delivery, not pickup.")
        end

        unless order.ready? || order.complete?
          return error_result("That order isn't ready yet. It will be ready in #{order.time_remaining_display}.")
        end

        # Check if character is at the fabrication room
        if order.fabrication_room_id && character_instance.current_room_id != order.fabrication_room_id
          return error_result("You need to be at #{order.fabrication_room&.name || 'the workshop'} to pick up this order.")
        end

        result = FabricationService.pickup_order(character_instance, order)

        if result[:success]
          success_result(
            result[:message],
            type: :fabrication_pickup,
            data: {
              action: 'pickup',
              item_id: result[:item]&.id,
              item_name: result[:item]&.name,
              order_id: order.id
            }
          )
        else
          error_result(result[:message])
        end
      end

      # Fabricate an item instantly (sci-fi/near-future eras)
      def fabricate_instantly(pattern)
        item = pattern.instantiate(character_instance: character_instance)

        success_result(
          "You fabricate #{item.name}.",
          type: :message,
          data: {
            action: 'fabricate',
            item_id: item.id,
            item_name: item.name,
            pattern_id: pattern.id
          }
        )
      end

      # Show quickmenu for delivery options (pickup vs delivery)
      def show_delivery_options(pattern)
        fabrication_time = FabricationService.calculate_time(pattern)
        time_display = format_fabrication_time(fabrication_time)

        options = [
          {
            label: 'Wait here and pick up when ready',
            description: "Return here in #{time_display} to collect your item",
            id: 'pickup'
          }
        ]

        # Only offer delivery if character has a home
        home_room = find_home_room
        if home_room
          options << {
            label: "Deliver to #{home_room.name}",
            description: "Item will be delivered to your home when ready",
            id: 'delivery'
          }
        end

        options << {
          label: 'Cancel',
          description: "Don't fabricate this item",
          id: 'cancel'
        }

        create_quickmenu(
          character_instance,
          "This will take approximately #{time_display} to craft.\nHow would you like to receive your #{pattern.description}?",
          options,
          context: {
            command: 'fabricate',
            action: 'fabricate_delivery_choice',
            pattern_id: pattern.id,
            fabrication_time: fabrication_time,
            home_room_id: home_room&.id
          }
        )
      end

      # Handle the delivery choice quickmenu response
      def handle_quickmenu_response(selected_key, context)
        pattern = Pattern[context['pattern_id']]
        return error_result("Pattern not found.") unless pattern

        case selected_option
        when 'cancel'
          return success_result("Fabrication cancelled.")
        when 'pickup'
          return start_fabrication_order(pattern, 'pickup', nil)
        when 'delivery'
          home_room = Room[context['home_room_id']]
          return error_result("You don't have a home to deliver to.") unless home_room
          return start_fabrication_order(pattern, 'delivery', home_room)
        end

        error_result("Invalid option selected.")
      end

      # Start a fabrication order
      def start_fabrication_order(pattern, delivery_method, delivery_room)
        order = FabricationService.start_fabrication(
          character_instance,
          pattern,
          delivery_method: delivery_method,
          delivery_room: delivery_room
        )

        fabrication_time = FabricationService.calculate_time(pattern)

        message = if delivery_method == 'delivery'
          FabricationService.delivery_started_message(pattern, delivery_room, fabrication_time)
        else
          FabricationService.crafting_started_message(pattern, fabrication_time)
        end

        success_result(
          message,
          type: :fabrication_started,
          data: {
            action: 'fabrication_started',
            order_id: order.id,
            pattern_id: pattern.id,
            pattern_name: pattern.description,
            delivery_method: delivery_method,
            delivery_room_name: delivery_room&.name,
            completes_at: order.completes_at&.iso8601,
            time_display: order.time_remaining_display
          }
        )
      end

      def find_owned_pattern(name)
        name_lower = name.downcase.strip

        # First try direct ILIKE search (works for clean descriptions)
        patterns = Pattern.where(Sequel.ilike(:description, "%#{name_lower}%")).limit(10).all

        # If no results, search with HTML stripped (some descriptions have color spans)
        if patterns.empty?
          all_patterns = Pattern.limit(200).all
          patterns = all_patterns.select do |p|
            strip_html(p.description).downcase.include?(name_lower)
          end.first(10)
        end

        # Use centralized resolver for matching from the found patterns
        TargetResolverService.resolve(
          query: name,
          candidates: patterns,
          name_field: nil,
          description_field: :description
        )
      end

      def find_home_room
        # Find a room owned by the character
        character = character_instance.character
        Room.where(owner_id: character.id).first
      end

      def fabricate_deck
        character = character_instance.character

        # Find deck patterns owned by character
        owned_patterns = DeckPattern.where(creator_id: character.id)
                                    .or(is_public: true)
                                    .or(id: DeckOwnership.where(character_id: character.id).select(:deck_pattern_id))
                                    .all

        if owned_patterns.empty?
          return error_result("You don't own any deck patterns. Visit a card shop to acquire one.")
        end

        if owned_patterns.count == 1
          pattern = owned_patterns.first
        else
          # Multiple patterns - show quickmenu for selection
          options = owned_patterns.map do |dp|
            { label: dp.name, description: "#{dp.card_count || 'Standard'} card deck", id: dp.id }
          end

          return create_quickmenu(
            character_instance,
            "Which deck pattern would you like to fabricate?",
            options,
            context: {
              command: 'fabricate',
              action: 'fabricate_deck',
              match_ids: owned_patterns.map(&:id)
            }
          )
        end

        # Create deck instance
        deck = pattern.create_deck_for(character_instance)

        success_result(
          "You conjure #{pattern.name} with #{deck.remaining_count} cards.",
          type: :message,
          data: {
            action: 'fabricate_deck',
            deck_id: deck.id,
            pattern_id: pattern.id,
            pattern_name: pattern.name,
            card_count: deck.remaining_count
          }
        )
      end

      # Era-appropriate error message for no facility
      def no_facility_message
        era = EraService.current_era
        case era
        when :medieval, :gaslight
          "You need to visit a craftsman's workshop to fabricate items."
        when :modern
          "You need access to a shop or workshop to fabricate items."
        when :near_future, :scifi
          "You need access to a fabrication facility to create items."
        else
          "You need access to a materializer or workshop to fabricate items."
        end
      end

      # Era-appropriate error message for wrong facility type
      def wrong_facility_message(pattern)
        era = EraService.current_era
        facility_type = if pattern.clothing?
          'tailor or fashion shop'
        elsif pattern.jewelry?
          'jeweler or crafting studio'
        elsif pattern.weapon?
          'forge, armory, or blacksmith'
        elsif pattern.tattoo?
          'tattoo parlor or clinic'
        elsif pattern.pet?
          era == :scifi ? 'cloning lab' : 'pet breeder'
        else
          'appropriate facility'
        end

        "This facility cannot create that type of item. You need a #{facility_type}."
      end

      def format_fabrication_time(seconds)
        if seconds >= 3600
          hours = (seconds / 3600.0).round(1)
          hours == hours.to_i ? "#{hours.to_i} hour#{'s' if hours.to_i != 1}" : "#{hours} hours"
        elsif seconds >= 60
          minutes = (seconds / 60.0).round
          "#{minutes} minute#{'s' if minutes != 1}"
        else
          "#{seconds} second#{'s' if seconds != 1}"
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Crafting::Fabricate)
