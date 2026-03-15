# frozen_string_literal: true

# Service for calculating body position exposure and clothing visibility
# Inspired by Ravencroft's is_exposed and visible_clothing functions
#
# Performance: All public methods load worn_items ONCE with eager loading
# and pass the cached array through internal methods to avoid N+1 queries.
class VisibilityService
  class << self
    # Check if a body position is exposed (not covered by clothing)
    # @param character_instance [CharacterInstance] the character being examined
    # @param position_id [Integer] the body_position.id to check
    # @param viewer [CharacterInstance] the character viewing (optional)
    # @param xray [Boolean] bypass all visibility checks (admin mode)
    # @param worn_items_cache [Array<Item>, nil] pre-loaded worn items to avoid re-querying
    # @return [Boolean] true if the position is exposed
    def position_exposed?(character_instance, position_id, viewer: nil, xray: false, worn_items_cache: nil)
      return true if xray

      worn = worn_items_cache || load_worn_items(character_instance)

      # Check if any non-damaged clothing covers this position
      !worn.any? do |item|
        item.covers_position?(position_id) && !item_fully_torn?(item)
      end
    end

    # Get all visible clothing for a character
    # @param character_instance [CharacterInstance] the character being examined
    # @param viewer [CharacterInstance] the character viewing (optional)
    # @param xray [Boolean] bypass all visibility checks (admin mode)
    # @return [Array<Item>] sorted list of visible worn items
    def visible_clothing(character_instance, viewer: nil, xray: false)
      worn = load_worn_items(character_instance)

      visible_items = worn.select do |item|
        item_visible?(item, worn, viewer: viewer, xray: xray)
      end

      # Sort by display_order, then by worn_layer (higher layers first)
      clothing_config = GameConfig::Clothing
      visible_items.sort_by do |i|
        [i.display_order || clothing_config::DEFAULT_DISPLAY_ORDER,
         -(i.worn_layer || clothing_config::DEFAULT_WORN_LAYER)]
      end
    end

    # Check if a description element should be visible based on body position exposure
    # @param description [CharacterDescription] the description to check
    # @param character_instance [CharacterInstance] the character being examined
    # @param viewer [CharacterInstance] the character viewing (optional)
    # @param worn_items_cache [Array<Item>, nil] pre-loaded worn items to avoid re-querying
    # @return [Boolean] true if the description should be visible
    def description_visible?(description, character_instance, viewer: nil, worn_items_cache: nil)
      worn = worn_items_cache || load_worn_items(character_instance)

      # Body descriptions marked as concealed_by_clothing are only visible when
      # at least one covered position is exposed.
      if description.respond_to?(:concealed_by_clothing) && description.concealed_by_clothing
        position_ids = description_position_ids(description)
        return true if position_ids.empty?

        return position_ids.any? do |pos_id|
          position_exposed?(character_instance, pos_id, viewer: viewer, worn_items_cache: worn)
        end
      end

      desc_type = description.description_type
      return true unless desc_type

      # For CharacterDefaultDescription, description_type is a String (e.g., 'natural', 'tattoo')
      # These don't have visibility requirements - always visible
      return true if desc_type.is_a?(String)

      # Check if description requires specific body positions to be exposed
      # Use association cache if eager-loaded, otherwise query
      position_ids = if desc_type.associations.key?(:description_type_body_positions)
                       desc_type.description_type_body_positions.map(&:body_position_id)
                     else
                       desc_type.description_type_body_positions_dataset.select_map(:body_position_id)
                     end
      return true if position_ids.empty?

      mode = desc_type.visibility_mode || 'any'

      if mode == 'all'
        # All required positions must be exposed
        position_ids.all? { |pos_id| position_exposed?(character_instance, pos_id, viewer: viewer, worn_items_cache: worn) }
      else
        # At least one required position must be exposed
        position_ids.any? { |pos_id| position_exposed?(character_instance, pos_id, viewer: viewer, worn_items_cache: worn) }
      end
    end

    # Check if private content should be shown between two characters
    # Both must be in private_mode for adult content to be visible
    # @param viewer_instance [CharacterInstance] the character viewing
    # @param target_instance [CharacterInstance] the character being viewed
    # @return [Boolean] true if private content should be shown
    def show_private_content?(viewer_instance, target_instance)
      return false unless viewer_instance && target_instance
      viewer_instance.private_mode? && target_instance.private_mode?
    end

    # Filter descriptions based on privacy mode
    # @param descriptions [Array<CharacterDescription>] descriptions to filter
    # @param character_instance [CharacterInstance] the character being examined
    # @param viewer [CharacterInstance] the character viewing
    # @return [Array<CharacterDescription>] filtered descriptions
    def filter_descriptions_for_privacy(descriptions, character_instance, viewer:)
      show_private = show_private_content?(viewer, character_instance)
      worn = load_worn_items(character_instance)

      descriptions.select do |desc|
        desc_type = desc.description_type
        if desc_type && !desc_type.is_a?(String)
          # Skip private descriptions unless both are in private mode
          next false if desc_type.is_private && !show_private
        end

        # Check body position visibility
        description_visible?(desc, character_instance, viewer: viewer, worn_items_cache: worn)
      end
    end

    # Get visible items for a character, respecting privacy mode.
    # All items are always returned (never fully hidden). Use underwear_item?
    # to determine if images should be suppressed for non-private viewers.
    # @param character_instance [CharacterInstance] the character being examined
    # @param viewer [CharacterInstance] the character viewing
    # @param xray [Boolean] bypass all visibility checks
    # @return [Array<Item>] list of visible items
    def visible_clothing_for_privacy(character_instance, viewer:, xray: false)
      visible_clothing(character_instance, viewer: viewer, xray: xray)
    end

    # Check if an item is underwear based on its pattern category.
    # Used by display services to suppress images when not in private mode.
    # @param item [Item] the item to check
    # @return [Boolean] true if the item is categorized as underwear
    def underwear_item?(item)
      item.clothing_class == 'underwear'
    end

    private

    # Load worn items ONCE with eager-loaded associations for in-memory checks.
    # This eliminates N+1 queries from covers_position?, body_position_ids_covered, etc.
    def load_worn_items(character_instance)
      character_instance.objects_dataset
        .where(worn: true)
        .eager(:pattern, { item_body_positions: :body_position }, :holstered_weapons)
        .order(:display_order, Sequel.desc(:worn_layer))
        .all
    end

    # Check if an item is visible to a viewer
    def item_visible?(item, worn_items, viewer:, xray:)
      return true if xray
      return false if item.concealed?

      # Check if any covered position would be visible
      position_ids = item.body_position_ids_covered
      return true if position_ids.empty?

      # Item is visible if it's the outermost layer for any position it covers
      position_ids.any? do |pos_id|
        outermost_item_for_position?(item, worn_items, pos_id)
      end
    end

    # Check if this item is the outermost (visible) layer for a position
    def outermost_item_for_position?(item, worn_items, position_id)
      competing_items = worn_items.select do |other|
        other.id != item.id && other.covers_position?(position_id)
      end

      # No competing items = this item is visible
      return true if competing_items.empty?

      # Check if any competing item has a higher layer
      default_layer = GameConfig::Clothing::DEFAULT_WORN_LAYER
      competing_items.none? do |other|
        (other.worn_layer || default_layer) > (item.worn_layer || default_layer)
      end
    end

    # Check if an item is fully torn (100% damaged)
    def item_fully_torn?(item)
      (item.torn || 0) >= GameConfig::Clothing::FULLY_TORN_THRESHOLD
    end

    def description_position_ids(description)
      if description.respond_to?(:all_positions)
        return description.all_positions.map(&:id).compact.uniq
      end

      ids = []
      ids << description.body_position_id if description.respond_to?(:body_position_id) && description.body_position_id
      ids << description.body_position.id if ids.empty? && description.respond_to?(:body_position) && description.body_position
      ids.compact.uniq
    end

    # Cache private position IDs (these rarely change)
    def private_position_ids_cached
      @private_position_ids ||= BodyPosition.private_positions.select_map(:id)
    end
  end
end
