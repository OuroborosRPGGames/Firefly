# frozen_string_literal: true

# Shared helper for rendering inventory/equipment HTML sections.
#
# Used by Equipment and Inventory commands.
#
# Expects the including class to provide:
#   - format_item(item) -> String   — item-specific formatting (defined in each command)
module InventoryDisplayHelper
  def build_section(label, items)
    stacked = stack_items(items)
    section = +"<b>#{label}</b>"
    section << "<ul style='margin:0 0 0.4em;padding-left:1.2em;list-style:none'>"
    stacked.each do |entry|
      section << "<li>"
      section << entry[:display]
      section << " <span style='opacity:0.6'>(x#{entry[:count]})</span>" if entry[:count] > 1
      section << "</li>"
    end
    section << "</ul>"
    section
  end

  private

  def stack_items(items)
    grouped = items.group_by { |item| format_item(item) }
    grouped.map do |display, group|
      { display: display, count: group.length }
    end
  end
end
