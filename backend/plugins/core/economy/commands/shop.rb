# frozen_string_literal: true

require_relative '../concerns/shop_purchase_concern'

module Commands
  module Economy
    class Shop < Commands::Base::Command
      include ShopPurchaseConcern
      command_name 'shop'
      aliases 'browse', 'catalog', 'store', 'list'
      category :economy
      output_category :info
      help_text 'Open shop interface to browse, buy, and manage inventory'
      usage 'shop [buy <item>|stock|add <price> <item>|remove <item>]'
      examples 'shop', 'shop buy leather jacket', 'shop stock', 'shop add 50 sword'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip&.split(/\s+/, 2) || []

        # Check for shop in room
        shop = location.shop
        return error_result("There's no shop here.") unless shop

        # If command was invoked via 'list' alias with no arguments, show item list
        if args.empty? && parsed_input[:command_word]&.downcase == 'list'
          return show_item_list(shop)
        end

        if args.empty?
          return show_shop_menu(shop)
        end

        case args[0].downcase
        when 'buy', 'purchase'
          handle_buy(shop, args[1])
        when 'stock', 'inventory', 'manage'
          show_stock_management(shop)
        when 'add', 'addstock'
          handle_add_stock(shop, args[1])
        when 'remove', 'removestock'
          handle_remove_stock(shop, args[1])
        when 'list'
          show_item_list(shop)
        else
          # Treat as item name for buy
          handle_buy(shop, args.join(' '))
        end
      end

      private

      def show_shop_menu(shop)
        currency = default_currency
        balance_text = if currency
                         wallet = wallet_for(currency)
                         wallet_balance = wallet&.balance || 0
                         " (Balance: #{currency.format_amount(wallet_balance)})"
                       else
                         ""
                       end

        options = [
          { key: 'browse', label: 'Browse Items', description: 'View items for sale' },
          { key: 'buy', label: 'Buy', description: 'Quick purchase an item' }
        ]

        # Add owner options if applicable
        if shop_owner?(shop)
          options << { key: 'stock', label: 'Manage Stock', description: 'Add or remove items from your shop' }
        end

        shop_name = shop.display_name || 'Shop'

        create_quickmenu(
          character_instance,
          "#{shop_name}#{balance_text}",
          options,
          context: { command: 'shop', shop_id: shop.id }
        )
      end

      def handle_buy(shop, item_text)
        if blank?(item_text)
          return show_buy_menu(shop)
        end

        # Parse quantity and item name
        quantity, item_name = parse_buy_input(item_text)
        return error_result("Invalid quantity.") if quantity < 1

        # Find item in shop
        shop_item = find_shop_item(shop, item_name)
        return error_result("The shop doesn't sell '#{item_name}'.") unless shop_item
        return error_result("#{shop_item.description} is out of stock.") unless shop_item.available?

        if !shop_item.unlimited_stock? && shop_item.stock < quantity
          return error_result("Only #{shop_item.stock} #{shop_item.description} in stock.")
        end

        total_price = shop_item.effective_price * quantity

        if total_price > 0
          payment_result = process_payment(shop, total_price)
          return payment_result if payment_result[:type] == :error
        end

        items_created = []
        quantity.times do
          break unless shop.decrement_stock(shop_item.pattern_id)
          item = shop_item.pattern.instantiate(character_instance: character_instance)
          items_created << item
        end

        if items_created.empty?
          return error_result("Purchase failed - item went out of stock.")
        end

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

        success_result(
          msg,
          type: :message,
          output_category: :info,
          data: {
            action: 'buy',
            item_ids: items_created.map(&:id),
            item_name: shop_item.description,
            quantity: items_created.length,
            total_price: total_price,
            shop_id: shop.id
          }
        )
      end

      def show_buy_menu(shop)
        currency = default_currency
        items = shop.shop_items.to_a.select(&:available?)

        if items.empty?
          return error_result("This shop has nothing for sale right now.")
        end

        options = items.each_with_index.map do |item, idx|
          price_text = currency ? currency.format_amount(item.effective_price) : "free"
          stock_text = item.unlimited_stock? ? "" : " (#{item.stock} left)"

          {
            key: (idx + 1).to_s,
            label: plain_name(item.description),
            description: "#{price_text}#{stock_text}"
          }
        end

        options << { key: 'q', label: 'Cancel', description: 'Leave without buying' }

        item_data = items.map do |i|
          { id: i.id, pattern_id: i.pattern_id, name: plain_name(i.description), price: i.effective_price }
        end

        create_quickmenu(
          character_instance,
          "What would you like to buy?",
          options,
          context: { command: 'shop_buy', shop_id: shop.id, items: item_data }
        )
      end

      def show_stock_management(shop)
        unless shop_owner?(shop)
          return error_result("You don't own this shop.")
        end

        items = shop.shop_items.to_a
        currency = default_currency

        lines = ["<h3>Stock Management</h3>"]
        lines << ""

        if items.empty?
          lines << "Your shop has no items for sale."
        else
          items.each do |item|
            price_text = currency ? currency.format_amount(item.price) : "$#{item.price}"
            stock_text = item.unlimited_stock? ? "unlimited" : item.stock.to_s
            lines << "  #{item.description} - #{price_text} (stock: #{stock_text})"
          end
        end

        lines << ""
        lines << "Commands:"
        lines << "  shop add <price> <item>  - Add item from inventory"
        lines << "  shop remove <item>       - Remove item from shop"

        success_result(
          lines.join("\n"),
          type: :message,
          data: { action: 'stock_list', shop_id: shop.id, count: items.length }
        )
      end

      def handle_add_stock(shop, text)
        unless shop_owner?(shop)
          return error_result("You don't own this shop.")
        end

        return error_result("Add what? (e.g., 'shop add 50 leather jacket')") if blank?(text)

        parts = text.strip.split(/\s+/, 2)
        return error_result("Syntax: shop add <price> <item>") if parts.length < 2

        price_text = parts[0]
        item_name = parts[1]

        price = parse_price(price_text)
        return error_result("Invalid price. Use a positive number.") unless price
        return error_result("Price must be at least 1.") if price < 1

        item = find_item_in_inventory(item_name)
        return error_result("You don't have '#{item_name}' in your inventory.") unless item

        pattern = item.pattern
        return error_result("This item can't be sold in a shop.") unless pattern

        existing = shop.shop_items_dataset.first(pattern_id: pattern.id)
        currency = default_currency
        formatted_price = currency ? currency.format_amount(price) : "$#{price}"

        if existing
          existing.update(price: price, stock: existing.stock + 1)
          success_result(
            "Updated #{pattern.description} price to #{formatted_price}. Stock: #{existing.stock}",
            type: :message,
            data: { action: 'update_stock', pattern_id: pattern.id, price: price, new_stock: existing.stock }
          )
        else
          ShopItem.create(shop: shop, pattern: pattern, price: price, stock: 1)
          success_result(
            "Added #{pattern.description} to shop at #{formatted_price}.",
            type: :message,
            data: { action: 'add_stock', pattern_id: pattern.id, price: price, shop_id: shop.id }
          )
        end
      end

      def handle_remove_stock(shop, text)
        unless shop_owner?(shop)
          return error_result("You don't own this shop.")
        end

        return error_result("Remove what? (e.g., 'shop remove leather jacket')") if blank?(text)

        shop_item = find_shop_item(shop, text.strip)
        return error_result("The shop doesn't have '#{text.strip}' in stock.") unless shop_item

        item_desc = shop_item.description
        shop_item.destroy

        success_result(
          "Removed #{item_desc} from shop.",
          type: :message,
          data: { action: 'remove_stock', item_name: item_desc, shop_id: shop.id }
        )
      end

      def show_item_list(shop)
        currency = default_currency
        items = shop.available_items.eager(:pattern).all

        if items.empty?
          return error_result("#{shop.display_name || 'The shop'} has nothing for sale.")
        end

        listing = format_shop_listing(shop, items, currency)

        success_result(listing, type: :message, data: { action: 'shop_list', shop_id: shop.id, count: items.length })
      end

      # ========== Helpers ==========
      def shop_owner?(shop)
        outer_room = location.respond_to?(:outer_room) ? location.outer_room : location
        outer_room.owned_by?(character_instance.character)
      end

      def parse_price(text)
        return nil unless text.match?(/^\d+(\.\d{1,2})?$/)
        text.to_f.round
      end

      def find_shop_item(shop, name)
        TargetResolverService.resolve(
          query: name,
          candidates: shop.shop_items,
          name_field: :name,
          description_field: :description
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Shop)
