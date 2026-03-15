# frozen_string_literal: true

class Item < Sequel::Model(:objects)
  include StringHelper

  plugin :validation_helpers
  plugin :timestamps

  # === LEGACY ALIASES ===
  # item_type is stored in properties JSON for backward compatibility

  def item_type
    props = properties || {}
    props['item_type']
  end

  def item_type=(val)
    props = properties || {}
    props = props.dup if props.frozen?
    props['item_type'] = val
    self.properties = props
  end

  many_to_one :pattern
  many_to_one :character_instance
  many_to_one :room
  many_to_one :timeline
  many_to_one :stored_room, class: :Room, key: :stored_room_id
  many_to_one :transfer_destination_room, class: :Room, key: :transfer_destination_room_id
  one_to_many :item_body_positions, key: :item_id

  # Holster associations
  many_to_one :holster_container, class: :Item, key: :holstered_in_id
  one_to_many :holstered_weapons, class: :Item, key: :holstered_in_id
  
  def validate
    super
    # Set defaults before validation
    self.quantity ||= 1
    self.condition ||= 'good'
    
    validates_presence [:name]
    validates_integer :quantity, minimum: 1
    validates_includes ['excellent', 'good', 'fair', 'poor', 'broken'], :condition
    
    # Ensure object belongs to either character_instance OR room, not both
    if character_instance_id && room_id
      errors.add(:base, "Object cannot belong to both a character and a room")
    elsif !character_instance_id && !room_id
      errors.add(:base, "Object must belong to either a character or a room")
    end
    
    # Equipment validation
    if equipped && !character_instance_id
      errors.add(:equipped, "can only be true for objects owned by characters")
    end
  end
  
  def owned_by_character?
    !character_instance_id.nil?
  end
  
  def in_room?
    !room_id.nil?
  end
  
  def stackable?
    # Delegate to pattern's unified_object_type if available
    # Default to false for standalone objects
    false
  end

  def tradeable?
    # Delegate to pattern's unified_object_type if available
    # Default to true for standalone objects
    true
  end
  
  def move_to_character(character_instance)
    previous_owner_id = character_instance_id

    update(
      character_instance: character_instance,
      room: nil,
      worn: false,
      held: false,
      equipped: false,
      equipment_slot: nil,
      stored: false,
      stored_room_id: nil,
      transfer_started_at: nil,
      transfer_destination_room_id: nil,
      holstered_in_id: nil
    )

    clear_item_game_scores_for_previous_owner(previous_owner_id)
  end
  
  def move_to_room(room)
    previous_owner_id = character_instance_id

    update(
      character_instance: nil,
      room: room,
      worn: false,
      held: false,
      equipped: false,
      equipment_slot: nil,
      stored: false,
      stored_room_id: nil,
      transfer_started_at: nil,
      transfer_destination_room_id: nil,
      holstered_in_id: nil
    )

    clear_item_game_scores_for_previous_owner(previous_owner_id)
  end
  
  def equip(slot = nil)
    return false unless character_instance_id
    update(equipped: true, equipment_slot: slot)
  end
  
  def unequip
    update(equipped: false, equipment_slot: nil)
  end

  def equipped?
    equipped == true
  end

  # Clothing-specific methods
  def worn?
    worn == true
  end

  # Wear an item
  # For piercings, must specify position and character must be pierced there
  # @param position [String, nil] Required for piercings - the body position to wear at
  # @return [Boolean, String] true if successful, error string if failed
  def wear!(position: nil)
    return false unless character_instance_id

    if piercing?
      return "You need to specify a body position for the piercing." if position.nil?

      ci = character_instance
      normalized = position.to_s.downcase.strip

      unless ci.pierced_at?(normalized)
        return "You don't have a piercing hole at #{position}. Use 'pierce' to get one."
      end

      # Check if something else is already worn there
      existing = ci.piercings_at(normalized)
      if existing.any? { |p| p.id != id }
        return "You already have a piercing worn at #{position}. Remove it first."
      end

      update(worn: true, piercing_position: normalized)
    else
      update(worn: true)
    end
    true
  end

  def remove!
    if piercing?
      update(worn: false, piercing_position: nil)
    else
      update(worn: false)
    end
  end

  def clothing?
    is_clothing == true
  end

  def jewelry?
    is_jewelry == true
  end

  # Mapping of unified_object_type categories to outfit classes
  CATEGORY_TO_OUTFIT_CLASS = {
    # Underwear categories
    'underwear' => 'underwear', 'lingerie' => 'underwear', 'bra' => 'underwear',
    'panties' => 'underwear', 'boxers' => 'underwear', 'briefs' => 'underwear',
    # Overwear categories
    'jacket' => 'overwear', 'coat' => 'overwear', 'sweater' => 'overwear',
    'hoodie' => 'overwear', 'cardigan' => 'overwear', 'blazer' => 'overwear',
    'vest' => 'overwear', 'poncho' => 'overwear', 'cloak' => 'overwear',
    'robe' => 'overwear', 'overcoat' => 'overwear', 'outerwear' => 'overwear',
    # Bottoms categories
    'pants' => 'bottoms', 'trousers' => 'bottoms', 'jeans' => 'bottoms',
    'shorts' => 'bottoms', 'skirt' => 'bottoms', 'leggings' => 'bottoms',
    'slacks' => 'bottoms', 'capris' => 'bottoms', 'bottoms' => 'bottoms',
    # Top categories
    'shirt' => 'top', 'blouse' => 'top', 't-shirt' => 'top', 'tshirt' => 'top',
    'tank' => 'top', 'top' => 'top', 'tunic' => 'top', 'polo' => 'top',
    'camisole' => 'top', 'halter' => 'top', 'tee' => 'top',
    # Jewelry categories
    'ring' => 'jewelry', 'necklace' => 'jewelry', 'bracelet' => 'jewelry',
    'earring' => 'jewelry', 'anklet' => 'jewelry', 'brooch' => 'jewelry',
    'pendant' => 'jewelry', 'chain' => 'jewelry', 'jewelry' => 'jewelry',
    # Accessory categories
    'hat' => 'accessories', 'cap' => 'accessories', 'scarf' => 'accessories',
    'gloves' => 'accessories', 'belt' => 'accessories', 'watch' => 'accessories',
    'bag' => 'accessories', 'purse' => 'accessories', 'sunglasses' => 'accessories',
    'glasses' => 'accessories', 'tie' => 'accessories', 'bow' => 'accessories',
    'headband' => 'accessories', 'bandana' => 'accessories', 'beanie' => 'accessories',
    'mask' => 'accessories', 'socks' => 'accessories', 'stockings' => 'accessories',
    'accessories' => 'accessories'
  }.freeze

  # Determine the clothing class for this item
  # Used by outfit system to decide what gets removed when wearing an outfit
  # @return [String] One of: underwear, overwear, bottoms, top, jewelry, accessories, other
  def clothing_class
    # Jewelry is easy - check the flag or pattern type
    return 'jewelry' if jewelry? || pattern&.jewelry?

    # Check unified_object_type category first (most reliable)
    category = pattern&.category&.downcase
    if category && CATEGORY_TO_OUTFIT_CLASS[category]
      return CATEGORY_TO_OUTFIT_CLASS[category]
    end

    # Check subcategory
    subcategory = pattern&.subcategory&.downcase
    if subcategory && CATEGORY_TO_OUTFIT_CLASS[subcategory]
      return CATEGORY_TO_OUTFIT_CLASS[subcategory]
    end

    # Fallback: word boundary matching in item name
    # Use word boundaries to avoid partial matches (e.g., "diamond" containing "bra")
    item_name_lower = name.to_s.downcase
    CATEGORY_TO_OUTFIT_CLASS.each do |keyword, outfit_class|
      # Match whole word only (word boundary or start/end of string)
      if item_name_lower.match?(/\b#{Regexp.escape(keyword)}\b/)
        return outfit_class
      end
    end

    # Default to 'other' if no match
    'other'
  end

  def tattoo?
    is_tattoo == true
  end

  def piercing?
    is_piercing == true
  end

  # Override image_url to prefer pattern's image
  # Falls back to own column value, then checks if description contains an image path
  def image_url
    pattern_url = pattern&.image_url
    return pattern_url if present?(pattern_url)

    return self[:image_url] if present?(self[:image_url])

    # Some items store image paths in the description field
    desc = self[:description]
    desc if present?(desc) && desc.match?(/\.(png|jpe?g|gif|webp|svg)\z/i)
  end

  # Thumbnail just uses image_url (no separate thumbnail needed)
  def thumbnail_url
    image_url
  end

  def has_image?
    present?(image_url)
  end
  alias image? has_image?

  def has_thumbnail?
    has_image?
  end
  alias thumbnail? has_thumbnail?

  # ========================================
  # Timeline System Methods
  # ========================================

  # Check if this item is visible in a specific timeline
  # Items without timeline_id are visible everywhere (primary timeline items)
  # Items with timeline_id are only visible in that timeline
  def visible_in_timeline?(timeline_or_id)
    return true if timeline_id.nil?  # No timeline = visible everywhere

    tid = timeline_or_id.is_a?(Timeline) ? timeline_or_id.id : timeline_or_id
    timeline_id == tid
  end

  # Check if this item is visible to a specific character instance
  def visible_to?(viewer)
    return true if timeline_id.nil?  # Primary timeline items always visible

    viewer_timeline_id = viewer.timeline_id
    return false if viewer_timeline_id.nil?  # Viewer in primary can't see timeline items

    timeline_id == viewer_timeline_id
  end

  # Scope for items visible in a specific timeline
  def self.visible_in_timeline(timeline)
    tl_id = timeline.is_a?(Timeline) ? timeline.id : timeline
    where(Sequel.|({ timeline_id: nil }, { timeline_id: tl_id }))
  end

  # Scope for items visible to a character instance
  def self.visible_to(character_instance)
    if character_instance.timeline_id
      visible_in_timeline(character_instance.timeline_id)
    else
      where(timeline_id: nil)  # Primary timeline only sees primary items
    end
  end

  # ========================================
  # End Timeline System Methods
  # ========================================

  # Body positions this item covers
  def body_positions_covered
    item_body_positions_dataset.where(covers: true).eager(:body_position).all.map(&:body_position)
  end

  def body_position_ids_covered
    # Use eager-loaded association if available, otherwise query
    if associations.key?(:item_body_positions)
      item_body_positions.select(&:covers).map(&:body_position_id)
    else
      item_body_positions_dataset.where(covers: true).select_map(:body_position_id)
    end
  end

  def covers_position?(position_id)
    # Use eager-loaded association if available, otherwise query
    if associations.key?(:item_body_positions)
      return true if item_body_positions.any? { |ibp| ibp.body_position_id == position_id && ibp.covers }

      # Fallback: check pattern coverage for items missing ItemBodyPosition records
      if item_body_positions.empty? && pattern
        body_pos = BodyPosition[position_id]
        return false unless body_pos

        pattern.resolve_body_positions_ids.include?(position_id)
      else
        false
      end
    else
      return true if item_body_positions_dataset.where(body_position_id: position_id, covers: true).any?

      # Fallback: check pattern coverage for items missing ItemBodyPosition records
      if item_body_positions_dataset.empty? && pattern
        body_pos = BodyPosition[position_id]
        return false unless body_pos

        pattern.resolve_body_positions_ids.include?(position_id)
      else
        false
      end
    end
  end

  def covers_private_position?
    item_body_positions_dataset
      .join(:body_positions, id: :body_position_id)
      .where(Sequel[:body_positions][:is_private] => true)
      .where(Sequel[:item_body_positions][:covers] => true)
      .any?
  end

  # Visibility layer for overlap calculation
  def visibility_layer
    worn_layer || 0
  end

  # Damage level (0 = pristine, 10 = destroyed)
  def torn?
    (torn || 0) > 0
  end

  def damage_percentage
    ((torn || 0) * 10).clamp(0, 100)
  end

  def concealed?
    concealed == true
  end

  def zipped?
    zipped == true
  end

  # Hold/pocket methods - held items are visibly displayed in hand
  def held?
    held == true
  end

  def hold!
    return false unless character_instance_id
    update(held: true)
  end

  def pocket!
    update(held: false)
  end

  # ========================================
  # Holster/Sheath Methods
  # ========================================

  # Check if this weapon is currently in a holster
  def holstered?
    !holstered_in_id.nil?
  end

  # Get the holster item this weapon is in
  def holster_item
    return nil unless holstered?

    holster_container
  end

  # Check if this holster can accept a weapon
  def can_holster?(weapon)
    return false unless pattern&.holster?
    return false unless pattern.accepts_weapon_type?(weapon.pattern)
    return false if holstered_weapons_count >= pattern.holster_capacity

    true
  end

  # Count weapons currently in this holster
  def holstered_weapons_count
    Item.where(holstered_in_id: id).count
  end

  # Place a weapon in this holster
  def holster_weapon!(weapon)
    return false unless can_holster?(weapon)

    weapon.update(holstered_in_id: id, held: false)
    true
  end

  # Remove this weapon from its holster
  def unholster!
    return false unless holstered?

    update(holstered_in_id: nil)
    true
  end

  # ========================================
  # End Holster/Sheath Methods
  # ========================================

  # Consumable methods
  def consumable?
    pattern&.consumable?
  end

  def food?
    pattern&.food?
  end

  def drinkable?
    pattern&.drink?
  end

  def smokeable?
    pattern&.smokeable?
  end

  def being_consumed?
    !consume_remaining.nil?
  end

  def start_consuming!
    consume_time = pattern&.consume_time || 10
    update(consume_remaining: consume_time)
  end

  def consume_tick!
    return false unless being_consumed?

    new_remaining = (consume_remaining || 1) - 1
    if new_remaining <= 0
      finish_consuming!
      true  # finished
    else
      update(consume_remaining: new_remaining)
      false  # still consuming
    end
  end

  def finish_consuming!
    update(consume_remaining: nil)
    # Reduce quantity or destroy item
    if quantity && quantity > 1
      update(quantity: quantity - 1)
    else
      destroy
    end
  end

  def taste_text
    pattern&.taste
  end

  def effect_text
    pattern&.effect
  end

  # Storage methods - items can be stored in vault/wardrobe
  TRANSFER_DURATION_HOURS = 12

  def stored?
    stored == true
  end

  def store!(room = nil)
    return false unless character_instance_id

    update(
      stored: true,
      stored_room_id: room&.id,
      worn: false,
      held: false,
      equipped: false,
      equipment_slot: nil
    )
    true
  end

  def retrieve!
    update(stored: false)
    true
  end

  # Transfer methods - move items between stash locations with delay
  def in_transit?
    !transfer_started_at.nil?
  end

  def transfer_ready?
    return false unless in_transit?

    Time.now >= transfer_started_at + (TRANSFER_DURATION_HOURS * 3600)
  end

  def time_until_transfer_ready
    return 0 unless in_transit?

    remaining = (transfer_started_at + (TRANSFER_DURATION_HOURS * 3600)) - Time.now
    [remaining, 0].max
  end

  def start_transfer!(destination_room)
    update(
      transfer_started_at: Time.now,
      transfer_destination_room_id: destination_room.id
    )
  end

  def complete_transfer!
    update(
      stored_room_id: transfer_destination_room_id,
      transfer_started_at: nil,
      transfer_destination_room_id: nil
    )
  end

  def cancel_transfer!
    update(
      transfer_started_at: nil,
      transfer_destination_room_id: nil
    )
  end

  # Get all stored items for a character instance (legacy - all rooms)
  def self.stored_items_for(character_instance)
    where(character_instance_id: character_instance.id, stored: true).order(:name)
  end

  # Get all stored items currently available in wardrobes (not in transit)
  def self.available_stored_items_for(character_instance)
    where(character_instance_id: character_instance.id, stored: true, transfer_started_at: nil).order(:name)
  end

  # Get items stored in a specific room (not in transit)
  # Also includes legacy items with nil stored_room_id for backward compatibility
  def self.stored_in_room(character_instance, room)
    where(character_instance_id: character_instance.id, stored: true, transfer_started_at: nil)
      .where(Sequel.|({ stored_room_id: room.id }, { stored_room_id: nil }))
      .order(:name)
  end

  # Get items currently in transit for a character
  def self.in_transit_for(character_instance)
    where(character_instance_id: character_instance.id, stored: true)
      .exclude(transfer_started_at: nil)
  end

  # Get items ready for transfer completion
  def self.ready_for_transfer_completion
    where { transfer_started_at <= Time.now - (TRANSFER_DURATION_HOURS * 3600) }
      .exclude(transfer_started_at: nil)
  end

  # ========================================
  # Pet Animation System Methods
  # ========================================

  # Check if this item is a pet instance
  # @return [Boolean]
  def pet?
    is_pet_instance == true
  end

  # Get the owner character instance (alias for consistency)
  # @return [CharacterInstance, nil]
  def owner_instance
    character_instance
  end

  # Get the owner character (through character_instance)
  # @return [Character, nil]
  def owner_character
    owner_instance&.character
  end

  # Get the owner's name for LLM context
  # @return [String]
  def owner_name
    owner_character&.forename || 'someone'
  end

  def clear_item_game_scores_for_previous_owner(previous_owner_id)
    return unless defined?(GameScore)
    return unless previous_owner_id && previous_owner_id != character_instance_id

    GameScore.clear_for_items(previous_owner_id)
  rescue StandardError => e
    warn "[Item] Failed to clear game scores for owner #{previous_owner_id}: #{e.message}"
  end

  # Pet type name from pattern (e.g., "Tiny Elephant")
  # @return [String]
  def pet_type_name
    pattern&.pet_type_name || 'pet'
  end

  # Pet description from pattern (e.g., "a tiny eight-inch tall elephant")
  # @return [String]
  def pet_description
    pattern&.pet_description || 'a magical pet'
  end

  # Pet sounds from pattern (e.g., "trumpets softly, flaps its ears")
  # @return [String]
  def pet_sounds
    pattern&.pet_sounds || 'makes soft sounds'
  end

  # Check if pet is on cooldown
  # @param cooldown_seconds [Integer] cooldown duration (default 120s)
  # @return [Boolean]
  def pet_on_cooldown?(cooldown_seconds = 120)
    return false if pet_last_animation_at.nil?

    pet_last_animation_at > Time.now - cooldown_seconds
  end

  # Update the last animation timestamp
  def update_pet_animation_time!
    update(pet_last_animation_at: Time.now)
  end

  # Add an emote to the pet's history (keeps last 5)
  # @param emote_text [String] the emote to add
  def add_emote_to_history(emote_text)
    history = pet_emote_history || []
    history = history.to_a if history.respond_to?(:to_a)
    history << emote_text
    history = history.last(5) # Keep only last 5
    update(pet_emote_history: Sequel.pg_array(history, :text))
  end

  # Get recent emote context for LLM prompt
  # @return [String]
  def recent_emote_context
    return '(No recent activity in the room)' if pet_emote_history.nil? || pet_emote_history.empty?

    pet_emote_history.to_a.join("\n")
  end

  # ========================================
  # Pet Animation Scopes
  # ========================================

  # Find pet items in a room (on the ground)
  # @param room_id [Integer]
  # @return [Sequel::Dataset]
  def self.pets_in_room(room_id)
    where(room_id: room_id, is_pet_instance: true)
  end

  # Find pets held by characters currently in a specific room
  # A pet is "held" when it has a character_instance_id and is not stored
  # @param room_id [Integer]
  # @return [Sequel::Dataset]
  def self.pets_held_in_room(room_id)
    join(:character_instances, id: :character_instance_id)
      .where(is_pet_instance: true)
      .where(Sequel[:objects][:held] => true)
      .where(Sequel[:character_instances][:current_room_id] => room_id)
      .select_all(:objects)
  end

  # ========================================
  # End Pet Animation System Methods
  # ========================================
end
