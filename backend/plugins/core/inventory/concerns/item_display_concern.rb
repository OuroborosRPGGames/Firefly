# frozen_string_literal: true

# Shared item-display formatting for inventory/equipment commands.
#
# Provides +format_item+ which renders an item's name plus optional
# condition and damage annotations as an HTML string.
#
# Commands that want to show stack quantity (e.g. InventoryCmd) should
# override +format_item+ and prepend their own quantity prefix before
# delegating to +super+, or call the shared helper directly.
#
# Usage:
#   include ItemDisplayConcern
module ItemDisplayConcern
  def format_item(item)
    parts = [item.name]

    unless item.condition == 'good'
      parts << "<span style='opacity:0.6'>(#{item.condition})</span>"
    end

    if item.torn?
      damage = case item.torn
               when 1..3 then 'slightly damaged'
               when 4..6 then 'damaged'
               when 7..9 then 'heavily damaged'
               else 'destroyed'
               end
      parts << "<span style='opacity:0.6'>(#{damage})</span>"
    end

    parts.join(' ')
  end
end
