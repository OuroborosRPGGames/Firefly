# frozen_string_literal: true

module Commands
  module Economy
    class Preview < Commands::Base::Command
      command_name 'preview'
      aliases 'examine item', 'inspect item', 'try on'
      category :economy
      help_text 'Preview details of an item for sale in a shop'
      usage 'preview <item name>'
      examples 'preview leather jacket', 'preview sword'

      protected

      def perform_command(parsed_input)
        text = (parsed_input[:text] || '').strip

        if text.empty?
          return error_result("Preview what? Usage: preview <item name>")
        end

        # Check for shop in room
        shop = location.shop
        return error_result("There's no shop here.") unless shop

        # Find item in shop
        shop_item = find_shop_item(shop, text)
        return error_result("The shop doesn't sell anything matching '#{text}'.") unless shop_item

        pattern = shop_item.pattern
        return error_result("Item data not found.") unless pattern

        # Price
        price_text = if shop_item.effective_price > 0
                       currency = default_currency
                       currency ? currency.format_amount(shop_item.effective_price) : shop_item.effective_price.to_s
                     else
                       'Free'
                     end

        # Stock
        stock_text = if shop_item.unlimited_stock?
                       'In Stock'
                     elsif shop_item.stock.positive?
                       "#{shop_item.stock} remaining"
                     else
                       'Out of stock'
                     end

        # Build description with shop details
        desc_parts = []
        desc_parts << pattern.desc_desc if pattern.respond_to?(:desc_desc) && !pattern.desc_desc.to_s.strip.empty?
        desc_parts << "#{item_category_label(pattern)} | #{price_text} | #{stock_text}"

        # Build structured item data for client-side rendering
        item_data = {
          name: pattern.description,
          description: desc_parts.join("\n"),
          image_url: pattern.image_url,
          display_type: :item
        }

        success_result(
          format_preview_text(pattern, price_text, stock_text),
          type: :message,
          structured: item_data,
          object_id: pattern.id,
          target: pattern.description
        )
      end

      private

      def item_category_label(pattern)
        if pattern.clothing? then 'Clothing'
        elsif pattern.jewelry? then 'Jewelry'
        elsif pattern.weapon? then 'Weapon'
        elsif pattern.tattoo? then 'Tattoo'
        elsif pattern.consumable? then 'Consumable'
        elsif pattern.pet? then 'Pet'
        else 'Item'
        end
      end

      def format_preview_text(pattern, price_text, stock_text)
        lines = ["You examine #{pattern.description}:"]
        lines << pattern.desc_desc if pattern.respond_to?(:desc_desc) && !pattern.desc_desc.to_s.strip.empty?
        lines << "Price: #{price_text} | Stock: #{stock_text}"
        lines.join("\n")
      end

      def find_shop_item(shop, name)
        # Use centralized resolver with name and description (which may have HTML)
        TargetResolverService.resolve(
          query: name,
          candidates: shop.shop_items.to_a,
          name_field: :name,
          description_field: :description
        )
      end

      # Uses inherited default_currency from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Preview)
