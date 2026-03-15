# frozen_string_literal: true

# Shared purchase/listing helpers for economy shop commands.
module ShopPurchaseConcern
  def format_shop_listing(shop, items, currency)
    by_category = items.group_by { |i| i.category || 'Other' }

    # Build item data for client-side popup
    item_data = []
    item_number = 0
    by_category.keys.sort.each do |_cat|
      by_category[_cat].each do |item|
        item_number += 1
        price = item.effective_price
        pattern = item.pattern
        raw_desc = pattern&.desc_desc
        # desc_desc may contain an image path instead of a description
        img_url = pattern&.image_url
        desc_text = nil
        if raw_desc&.match?(%r{\A/.*\.(png|jpg|jpeg|gif|webp)\z}i)
          img_url ||= raw_desc
        else
          desc_text = raw_desc
        end
        item_data << {
          n: item_number,
          name: item.description,
          desc: desc_text || plain_name(item.description),
          img: img_url,
          price: price,
          pf: currency ? currency.format_amount(price) : "$#{price}",
          stock: item.unlimited_stock? ? -1 : item.stock
        }
      end
    end

    data_attr = item_data.to_json.gsub("'", '&#39;')
    html = "<div class='shop-listing' data-shop-items='#{data_attr}'>"
    html << "<b>#{shop.display_name || 'Shop'}</b>"

    item_number = 0
    by_category.keys.sort.each do |cat|
      html << "<span class='shop-category-header'>#{cat.capitalize}</span>"
      html << "<ol class='shop-item-list' start='#{item_number + 1}'>"
      by_category[cat].each do |item|
        item_number += 1
        price = item.effective_price
        price_text = currency ? currency.format_amount(price) : "$#{price}"
        stock_text = item.unlimited_stock? ? "" : " <span class='text-warning'>(#{item.stock} left)</span>"
        html << "<li class='shop-listing-item' data-item-idx='#{item_number - 1}'>[#{price_text}] #{item.description}#{stock_text}</li>"
      end
      html << "</ol>"
    end

    # Only show hint in tutorial rooms or free shops
    if location&.room_type == 'tutorial' || shop.free_items
      html << "<span class='shop-hint'>Type 'buy &lt;item&gt;' or 'buy &lt;number&gt;' to purchase.</span>"
    end

    html << "</div>"
    html
  end

  def parse_buy_input(text)
    parts = text.split(/\s+/, 2)
    if parts.length > 1 && parts[0].match?(/^\d+$/)
      [parts[0].to_i, parts[1]]
    else
      [1, text]
    end
  end

  def process_payment(shop, amount)
    currency = default_currency
    return error_result("No currency defined for this area.") unless currency

    wallet = wallet_for(currency)
    bank_account = bank_account_for(currency)

    wallet_balance = wallet&.balance || 0
    bank_balance = bank_account&.balance || 0
    total_available = wallet_balance + (shop.cash_shop ? 0 : bank_balance)

    if total_available < amount
      return error_result("You can't afford that. It costs #{currency.format_amount(amount)}.")
    end

    remaining = amount

    unless shop.cash_shop
      if bank_account && bank_account.balance > 0
        bank_debit = [remaining, bank_account.balance].min
        bank_account.withdraw(bank_debit)
        remaining -= bank_debit
      end
    end

    if remaining > 0 && wallet
      wallet.remove(remaining)
    end

    { type: :success }
  end
end
