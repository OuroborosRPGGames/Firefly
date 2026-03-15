# frozen_string_literal: true

require_relative '../concerns/shop_purchase_concern'

module Commands
  module Economy
    class Buy < Commands::Base::Command
      include ShopPurchaseConcern
      command_name 'buy'
      aliases 'purchase'
      category :economy
      help_text 'Purchase items from a shop'
      usage 'buy <item> | buy <number> | buy <quantity> <item>'
      examples 'buy leather jacket', 'buy 3', 'buy 2 potions'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]

        # Check for shop in room
        shop = location.shop
        return error_result("There's no shop here.") unless shop

        # Show shop listing if no item specified
        if blank?(text)
          return show_shop_listing(shop)
        end

        # Parse quantity and item name
        quantity, item_name = parse_buy_input(text.strip)
        return error_result("Invalid quantity.") if quantity < 1

        # Check if item_name is a number (buy by index)
        if item_name.match?(/^\d+$/)
          return buy_by_number(shop, item_name.to_i, quantity)
        end

        # Find item in shop with disambiguation support
        result = find_shop_item_with_disambiguation(shop, item_name)

        # If disambiguation needed, return the quickmenu
        if result[:disambiguation]
          return result[:result]
        end

        # If error (no match found)
        return error_result(result[:error] || "The shop doesn't sell '#{item_name}'.") if result[:error]

        complete_purchase(shop, result[:match], quantity)
      end

      private

      def buy_by_number(shop, number, quantity)
        items = shop.available_items.eager(:pattern).all
        return error_result("This shop has nothing for sale.") if items.empty?

        # Sort by category to match display order in format_shop_listing
        sorted_items = items.group_by { |i| i.category || 'Other' }
                            .sort_by { |cat, _| cat }
                            .flat_map { |_, cat_items| cat_items }

        if number < 1 || number > sorted_items.length
          return error_result("Invalid item number. Choose 1-#{sorted_items.length}.")
        end

        shop_item = sorted_items[number - 1]
        complete_purchase(shop, shop_item, quantity)
      end

      def complete_purchase(shop, shop_item, quantity)
        return error_result("#{shop_item.description} is out of stock.") unless shop_item.available?

        # Check stock for quantity
        if !shop_item.unlimited_stock? && shop_item.stock < quantity
          return error_result("Only #{shop_item.stock} #{shop_item.description} in stock.")
        end

        # Calculate price
        total_price = shop_item.effective_price * quantity

        # Handle payment if item is not free
        if total_price > 0
          payment_result = process_payment(shop, total_price)
          return payment_result if payment_result[:type] == :error
        end

        # Decrement stock and create item(s)
        items_created = []
        quantity.times do
          break unless shop.decrement_stock(shop_item.pattern_id)
          item = shop_item.pattern.instantiate(character_instance: character_instance)
          items_created << item
        end

        if items_created.empty?
          return error_result("Purchase failed - item went out of stock.")
        end

        # Build response
        item_desc = quantity > 1 ? "#{quantity} #{shop_item.description}s" : shop_item.description
        currency = default_currency

        msg = if total_price > 0
                price_text = currency.format_amount(total_price)
                "You buy #{item_desc} for #{price_text}."
              else
                "You buy #{item_desc}."
              end

        broadcast_to_room(
          "#{character_instance.character.full_name} buys #{item_desc}.",
          exclude_character: character_instance
        )

        # Re-show the shop listing after purchase
        remaining_items = shop.available_items.eager(:pattern).all
        if remaining_items.any?
          listing = format_shop_listing(shop, remaining_items, currency)
          msg = "#{msg}\n\n#{listing}"
        end

        success_result(msg)
      end

      # Show formatted shop listing
      def show_shop_listing(shop)
        currency = default_currency
        items = shop.available_items.eager(:pattern).all

        if items.empty?
          return error_result("This shop has nothing for sale right now.")
        end

        listing = format_shop_listing(shop, items, currency)

        success_result(listing, type: :message, data: { action: 'shop_list', shop_id: shop.id, count: items.length })
      end

      def find_shop_item_with_disambiguation(shop, name)
        candidates = shop.shop_items.to_a
        return { error: "The shop has nothing for sale." } if candidates.empty?

        result = TargetResolverService.resolve_with_disambiguation(
          query: name,
          candidates: candidates,
          name_field: :name,
          description_field: :description,
          display_field: :description,
          character_instance: character_instance,
          context: { command: 'buy', shop_id: shop.id }
        )

        if result[:quickmenu]
          { disambiguation: true, result: result[:quickmenu] }
        elsif result[:error]
          { error: result[:error] }
        else
          { match: result[:match] }
        end
      end

    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Buy)
