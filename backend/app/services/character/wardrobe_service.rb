# frozen_string_literal: true

# WardrobeService handles wardrobe operations including:
# - Fetching stored items
# - Creating items from patterns (at half cost)
# - Vault access validation
class WardrobeService
  include ResultHandler

  PATTERN_CREATE_COST_MULTIPLIER = 0.5

  # Maps tab names to UOT category arrays
  TAB_CATEGORIES = {
    'clothing'    => Pattern::CLOTHING_CATEGORIES,
    'jewelry'     => Pattern::JEWELRY_CATEGORIES,
    'consumables' => Pattern::CONSUMABLE_CATEGORIES,
    'weapons'     => Pattern::WEAPON_CATEGORIES,
    'other'       => Pattern::OTHER_CATEGORIES
  }.freeze

  # Maps UI subcategory labels to UOT category values
  CLOTHING_SUBCATEGORY_MAP = {
    'tops'        => %w[Top],
    'bottoms'     => %w[Pants Skirt],
    'dresses'     => %w[Dress Fullbody],
    'outerwear'   => %w[Outerwear],
    'shoes'       => %w[Shoes],
    'accessories' => %w[Accessory Bag],
    'underwear'   => %w[Underwear],
    'swimwear'    => %w[Swimwear]
  }.freeze

  JEWELRY_SUBCATEGORY_MAP = {
    'necklaces'  => %w[Necklace],
    'rings'      => %w[Ring],
    'bracelets'  => %w[Bracelet],
    'piercings'  => %w[Piercing]
  }.freeze

  # Reverse lookup: UOT category -> UI subcategory label
  SUBCATEGORY_REVERSE_MAP = {}.tap do |map|
    CLOTHING_SUBCATEGORY_MAP.each { |label, cats| cats.each { |c| map[c] = label } }
    JEWELRY_SUBCATEGORY_MAP.each { |label, cats| cats.each { |c| map[c] = label } }
  end.freeze

  def initialize(character_instance)
    @ci = character_instance
    @room = character_instance.current_room
  end

  # Check if character has vault access in current room
  def vault_accessible?
    return false unless @room

    @room.vault_accessible?(@ci.character)
  end

  # Get items filtered by tab category and optional subcategory
  def items_by_category(category, subcategory = nil, room_id: nil)
    complete_ready_transfers!

    # Start with unordered dataset to avoid ambiguous column after joins
    items = if room_id
              room = Room[room_id.to_i]
              room ? Item.stored_in_room(@ci, room).unordered : Item.available_stored_items_for(@ci).unordered
            else
              Item.available_stored_items_for(@ci).unordered
            end

    uot_categories = TAB_CATEGORIES[category]
    if uot_categories
      items = items.association_join(:pattern)
                   .join(:unified_object_types, id: Sequel[:pattern][:unified_object_type_id])
                   .where(Sequel[:unified_object_types][:category] => uot_categories)
                   .select_all(:objects)
                   .eager(:pattern)
    end

    if subcategory && subcategory != 'all'
      subcategory_map = subcategory_map_for(category)
      uot_cats = subcategory_map[subcategory]
      if uot_cats
        # If we haven't already joined, do it now
        unless uot_categories
          items = items.association_join(:pattern)
                       .join(:unified_object_types, id: Sequel[:pattern][:unified_object_type_id])
                       .select_all(:objects)
                       .eager(:pattern)
        end
        items = items.where(Sequel[:unified_object_types][:category] => uot_cats)
      end
    end

    items.order(Sequel[:objects][:name]).all
  end

  # Get patterns filtered by tab category
  def patterns_by_category(category)
    patterns = eligible_patterns
    uot_categories = TAB_CATEGORIES[category]

    if uot_categories
      patterns.join(:unified_object_types, id: :unified_object_type_id)
              .where(Sequel[:unified_object_types][:category] => uot_categories)
              .select_all(:patterns).all
    else
      patterns.all
    end
  end

  # Get patterns the character can use (from items they own/owned)
  def eligible_patterns
    owned_pattern_ids = @ci.objects_dataset
                           .exclude(pattern_id: nil)
                           .select_map(:pattern_id)
                           .uniq
    Pattern.where(Sequel[:patterns][:id] => owned_pattern_ids).eager(:unified_object_type).order(Sequel[:patterns][:description])
  end

  # Return subcategory labels that have items or patterns for a given tab category
  def available_subcategories(category)
    complete_ready_transfers!

    subcategory_map = subcategory_map_for(category)
    return [] if subcategory_map.empty?

    uot_categories = TAB_CATEGORIES[category] || []

    # Get distinct UOT categories from stored items
    item_uot_cats = Item.available_stored_items_for(@ci).unordered
                        .association_join(:pattern)
                        .join(:unified_object_types, id: Sequel[:pattern][:unified_object_type_id])
                        .where(Sequel[:unified_object_types][:category] => uot_categories)
                        .select_map(Sequel[:unified_object_types][:category])
                        .uniq

    # Get distinct UOT categories from eligible patterns
    pattern_uot_cats = eligible_patterns
                         .join(:unified_object_types, id: :unified_object_type_id)
                         .where(Sequel[:unified_object_types][:category] => uot_categories)
                         .select_map(Sequel[:unified_object_types][:category])
                         .uniq

    all_uot_cats = (item_uot_cats + pattern_uot_cats).uniq

    # Return only subcategory labels that have matching UOT categories
    subcategory_map.select { |_label, cats| (cats & all_uot_cats).any? }.keys
  end

  # Fetch item from storage to inventory
  def fetch_item(item_id)
    return error('No vault access') unless vault_accessible?
    complete_ready_transfers!

    item = Item.available_stored_items_for(@ci).where(id: item_id).first
    return error('Item not found') unless item

    item.retrieve!
    success("You retrieve #{item.name}.", data: { item: item })
  end

  # Fetch item and immediately wear it
  # For piercings: auto-selects position if only one exists, otherwise returns available positions
  def fetch_and_wear(item_id)
    result = fetch_item(item_id)
    return result unless result[:success]

    item = result[:item]

    if item.respond_to?(:piercing?) && item.piercing?
      positions = @ci.pierced_positions
      return error("You don't have any piercing holes. Use 'pierce' to get one first.") if positions.empty?

      if positions.length == 1
        # Auto-select the only position
        wear_result = item.wear!(position: positions.first)
        return error(wear_result) if wear_result.is_a?(String)

        return success("You retrieve and put #{item.name} in your #{positions.first} piercing.",
                       data: { item: item, worn: true, position: positions.first })
      else
        # Multiple positions - return them so caller can prompt
        return error("Multiple piercing positions available. Use 'wear #{item.name} on <position>'.",
                     data: { positions: positions, item: item, needs_position: true })
      end
    end

    if item.respond_to?(:wear!)
      wear_result = item.wear!
      return error(wear_result) if wear_result.is_a?(String)

      success("You retrieve and put on #{item.name}.", data: { item: item, worn: true })
    else
      result
    end
  end

  # Create a new item from a pattern (charges half cost)
  def create_from_pattern(pattern_id)
    return error('No vault access') unless vault_accessible?

    pattern = Pattern[pattern_id]
    return error('Pattern not found') unless pattern
    return error('You do not have access to this pattern') unless pattern_accessible?(pattern)

    cost = calculate_pattern_cost(pattern)

    if cost > 0
      wallet = primary_wallet
      return error('No wallet found') unless wallet
      return error("Insufficient funds. Cost: #{cost}") unless wallet.balance >= cost
      return error('Payment failed') unless wallet.remove(cost)
    end

    item = pattern.instantiate(character_instance: @ci)
    msg = cost > 0 ? "You create #{item.name} for #{cost}." : "You create #{item.name}."
    success(msg, data: { item: item, cost: cost })
  end

  # Destroy an item from storage
  def trash_item(item_id)
    return error('No vault access') unless vault_accessible?
    complete_ready_transfers!

    item = Item.available_stored_items_for(@ci).where(id: item_id).first
    return error('Item not found') unless item

    name = item.name.to_s.gsub(/<[^>]+>/, '')
    item.destroy
    success("You destroy #{name}.")
  end

  # Get wardrobe overview
  def overview
    { vault_accessible: vault_accessible?, current_room_id: @room&.id }
  end

  # Complete any ready transfers for this character instance
  def sync_transfers!
    complete_ready_transfers!
  end

  # Get rooms where character has stored items or owns
  def stash_rooms
    complete_ready_transfers!

    # Rooms with stored items
    item_room_ids = Item.where(character_instance_id: @ci.id, stored: true)
                        .exclude(stored_room_id: nil)
                        .select_map(:stored_room_id)
                        .uniq

    # Rooms owned by character
    owned_room_ids = Room.where(owner_id: @ci.character_id)
                         .select_map(:id)

    all_room_ids = (item_room_ids + owned_room_ids).uniq
    Room.where(id: all_room_ids).order(:name).all.map do |room|
      item_count = Item.where(character_instance_id: @ci.id, stored: true, stored_room_id: room.id, transfer_started_at: nil).count
      { id: room.id, name: room.name, item_count: item_count }
    end
  end

  # Get active transfers for character
  def active_transfers
    complete_ready_transfers!

    Item.in_transit_for(@ci).all.group_by { |i| [i.stored_room_id, i.transfer_destination_room_id] }.map do |key, items|
      from_room = Room[key[0]]
      to_room = Room[key[1]]
      earliest = items.map(&:transfer_started_at).min
      ready_at = earliest + (Item::TRANSFER_DURATION_HOURS * 3600)
      seconds_remaining = [(ready_at - Time.now).to_i, 0].max
      {
        from_room_id: key[0],
        from_room_name: from_room&.name || 'Unknown',
        to_room_id: key[1],
        to_room_name: to_room&.name || 'Unknown',
        item_count: items.size,
        seconds_remaining: seconds_remaining,
        ready: seconds_remaining == 0
      }
    end
  end

  # Start a bulk transfer of all items from one room to another
  def start_transfer(from_room_id, to_room_id)
    return error('No vault access') unless vault_accessible?
    return error('From and To rooms must be different') if from_room_id.to_i == to_room_id.to_i

    from_room = Room[from_room_id]
    to_room = Room[to_room_id]
    return error('Source room not found') unless from_room
    return error('Destination room not found') unless to_room

    items = Item.where(character_instance_id: @ci.id, stored: true, stored_room_id: from_room.id, transfer_started_at: nil).all
    return error('No items to transfer') if items.empty?

    items.each { |item| item.start_transfer!(to_room) }
    success("Started transfer of #{items.size} item(s) from #{from_room.name} to #{to_room.name}.")
  end

  # Cancel all transfers between two rooms
  def cancel_transfer(from_room_id, to_room_id)
    items = Item.where(
      character_instance_id: @ci.id,
      stored: true,
      stored_room_id: from_room_id,
      transfer_destination_room_id: to_room_id
    ).exclude(transfer_started_at: nil).all

    return error('No transfers found') if items.empty?

    items.each(&:cancel_transfer!)
    success("Cancelled transfer of #{items.size} item(s).")
  end

  private

  def subcategory_map_for(category)
    case category
    when 'clothing' then CLOTHING_SUBCATEGORY_MAP
    when 'jewelry' then JEWELRY_SUBCATEGORY_MAP
    else {}
    end
  end

  def pattern_accessible?(pattern)
    @ci.objects_dataset.where(pattern_id: pattern.id).any?
  end

  def calculate_pattern_cost(pattern)
    base_price = pattern.price || 0
    (base_price * PATTERN_CREATE_COST_MULTIPLIER).round
  end

  def primary_wallet
    @ci.wallets.first
  end

  def complete_ready_transfers!
    Item.ready_for_transfer_completion
        .where(character_instance_id: @ci.id, stored: true)
        .all
        .each(&:complete_transfer!)
  end

  # NOTE: error method is inherited from ResultHandler
end
