# frozen_string_literal: true

class Room < Sequel::Model
  include SeasonalContent

  plugin :validation_helpers
  plugin :timestamps

  # ========================================
  # Room Type Constants
  # ========================================

  # Room publicity levels
  # - secluded: Private space, not visible to outsiders (e.g., private apartments, hidden areas)
  # - semi_public: Partially visible, limited access (e.g., members-only clubs, gated areas)
  # - public: Fully visible and accessible (e.g., streets, shops, public spaces)
  PUBLICITY_LEVELS = %w[secluded semi_public public].freeze

  # ----------------------------------------
  # Room types are centrally defined in config/room_types.yml
  # and loaded via RoomTypeConfig. These constants delegate to
  # that config for backward compatibility.
  # ----------------------------------------

  # Category-grouped room types: { basic: ['standard', ...], services: ['shop', ...], ... }
  ROOM_TYPES = RoomTypeConfig.grouped_types

  # Flat list of all valid room types for validation
  VALID_ROOM_TYPES = RoomTypeConfig.all_types

  # City room types that are open-air (street, avenue, intersection)
  OUTDOOR_CITY_TYPES = RoomTypeConfig.tagged(:street).freeze

  # Battle map generation config per room type (used by BattleMapGeneratorService)
  # Delegates to RoomTypeConfig.battle_map(type)
  ROOM_TYPE_CONFIGS = RoomTypeConfig.all_types.each_with_object({}) do |type, hash|
    config = RoomTypeConfig.battle_map(type)
    # Only include types that have non-default configs
    hash[type] = config
  end.freeze

  # Default config for room types not in ROOM_TYPE_CONFIGS
  DEFAULT_ROOM_CONFIG = RoomTypeConfig.battle_map('__nonexistent__').freeze

  many_to_one :location
  many_to_one :inside_room, class: :Room
  one_to_many :contained_rooms, class: :Room, key: :inside_room_id
  one_to_many :character_instances, key: :current_room_id
  one_to_many :objects, class: :Item
  one_to_many :messages
  one_to_many :room_features
  one_to_many :connected_features, class: :RoomFeature, key: :connected_room_id
  one_to_many :outgoing_sightlines, class: :RoomSightline, key: :from_room_id
  one_to_many :incoming_sightlines, class: :RoomSightline, key: :to_room_id
  one_to_many :room_hexes
  one_to_one :shop
  one_to_many :places
  one_to_many :decorations
  many_to_one :owner, class: :Character, key: :owner_id
  one_to_many :room_unlocks
  one_to_many :graffiti
  one_to_one :jukebox

  def validate
    super
    validates_presence [:name, :location_id]
    validates_max_length 100, :name
    validates_includes VALID_ROOM_TYPES, :room_type
    validates_includes PUBLICITY_LEVELS, :publicity, allow_nil: true

    # Rooms must have dimensions specified for combat/positioning to work
    validate_room_bounds
  end

  def before_save
    super
    # Set default short_description if not provided
    self.short_description ||= name if StringHelper.blank?(short_description)
  end

  private

  # Validate that room bounds are properly set and within parent if nested
  def validate_room_bounds
    # All rooms must have dimensions
    if min_x.nil? || max_x.nil? || min_y.nil? || max_y.nil?
      errors.add(:base, 'Room dimensions (min_x, max_x, min_y, max_y) must be specified')
      return
    end

    # Validate min < max
    if min_x >= max_x
      errors.add(:base, 'min_x must be less than max_x')
    end
    if min_y >= max_y
      errors.add(:base, 'min_y must be less than max_y')
    end

    # If nested inside another room, validate bounds are within parent
    return unless inside_room_id

    parent = Room[inside_room_id]
    return unless parent&.min_x && parent&.max_x && parent&.min_y && parent&.max_y

    # Check X/Y bounds
    unless min_x >= parent.min_x && max_x <= parent.max_x &&
           min_y >= parent.min_y && max_y <= parent.max_y
      errors.add(:base, "Room bounds must be within parent room bounds (#{parent.min_x}-#{parent.max_x}, #{parent.min_y}-#{parent.max_y})")
    end

    # Check Z bounds (height) if parent has them defined
    if parent.min_z && parent.max_z && min_z && max_z
      unless min_z >= parent.min_z && max_z <= parent.max_z
        errors.add(:base, "Room height must be within parent room height (#{parent.min_z}-#{parent.max_z})")
      end
    end
  end

  public

  # Returns the best available description (long or short)
  def description
    (long_description && !long_description.empty?) ? long_description : short_description
  end

  # Get navigable spatial exits grouped by direction
  # Applies filtering for nesting level and distance limits
  # @return [Hash<Symbol, Array<Room>>] { north: [rooms], south: [rooms], ... }
  def spatial_exits
    RoomAdjacencyService.navigable_exits(self)
  end

  # Get raw adjacent rooms without filtering (for internal use)
  # @return [Hash<Symbol, Array<Room>>] { north: [rooms], south: [rooms], ... }
  def raw_adjacent_rooms
    RoomAdjacencyService.adjacent_rooms(self)
  end

  # Get passable exits in all directions (spatial only)
  # Excludes contained rooms and sibling rooms - they appear as nearby locations instead
  # Exception: outdoor city rooms (streets/intersections) that overlap are still navigable
  # @return [Array<Hash>] array of { direction:, room: } hashes for passable exits
  def passable_spatial_exits
    # Get contained room IDs to exclude (they show as nearby locations, not exits)
    contained_ids = RoomAdjacencyService.contained_rooms(self).map(&:id).to_set

    # Get sibling room IDs to exclude (rooms sharing same container)
    sibling_ids = sibling_room_ids

    is_outdoor = outdoor_room?

    exits = []
    spatial_exits.each do |direction, rooms|
      rooms.each do |room|
        next unless room.navigable?
        next unless RoomPassabilityService.can_pass?(self, room, direction)
        # Skip contained rooms - they appear in locations list, not exits
        # Exception: outdoor rooms (streets/intersections) that overlap are navigable
        next if contained_ids.include?(room.id) && !(is_outdoor && room.outdoor_room?)
        # Skip sibling rooms - they appear in locations list, not exits
        next if sibling_ids.include?(room.id)

        # Calculate distance between room centers
        distance = RoomAdjacencyService.distance_between(self, room)

        exits << { direction: direction, room: room, distance: distance }
      end
    end
    exits
  end

  # Get IDs of sibling rooms (rooms sharing the same container)
  # @return [Set<Integer>]
  def sibling_room_ids
    container = RoomAdjacencyService.containing_room(self)
    return Set.new unless container

    RoomAdjacencyService.contained_rooms(container)
                        .reject { |r| r.id == id }
                        .map(&:id)
                        .to_set
  end

  # Get all visible exits (includes blocked exits like closed doors)
  # Use this for look commands where you want to see exits even if blocked
  # @return [Array<Hash>] array of { direction:, room: } hashes for all visible exits
  def visible_spatial_exits
    exits = []
    RoomAdjacencyService.visible_exits(self).each do |direction, rooms|
      rooms.each do |room|
        next unless room.navigable?

        exits << { direction: direction, room: room }
      end
    end
    exits
  end
  
  def characters_here(reality_id = nil, viewer: nil)
    query = character_instances_dataset.where(online: true)
    query = query.where(reality_id: reality_id) if reality_id
    query = query.where(in_event_id: viewer.in_event_id) if viewer

    # Filter by flashback instancing if viewer is provided
    if viewer&.flashback_instanced?
      # Instanced viewers can only see their co-travelers (and themselves)
      co_traveler_ids = viewer.flashback_co_travelers || []
      co_traveler_ids = co_traveler_ids + [viewer.id]
      query = query.where(id: co_traveler_ids)
    elsif viewer
      # Normal viewers can't see flashback-instanced characters
      # unless the instanced character is a co-traveler with this viewer
      # For simplicity, just exclude all flashback-instanced characters
      query = query.where(flashback_instanced: false)
    end

    query
  end
  
  def objects_here
    objects_dataset.order(:name)
  end

  def visible_places
    places_dataset.where(invisible: false)
  end

  def visible_decorations
    decorations_dataset.order(:display_order)
  end

  # Returns a hash of { place_id => [characters] } plus { nil => [ungrouped characters] }
  def characters_by_place(reality_id = nil, viewer: nil)
    chars = characters_here(reality_id, viewer: viewer).eager(:character, :current_place).all

    grouped = Hash.new { |h, k| h[k] = [] }
    chars.each do |char_instance|
      grouped[char_instance.current_place_id] << char_instance
    end
    grouped
  end
  
  def full_path
    "#{location.zone.world.universe.name} > #{location.zone.world.name} > #{location.zone.name} > #{location.name} > #{name}"
  end
  
  # Get all rooms that this room has sight connections to
  def visible_rooms
    # Get rooms connected through features that allow sight
    connected_through_features = room_features
      .select { |f| f.allows_sight_through? && f.connected_room_id }
      .map(&:connected_room)
    
    # Get rooms connected through incoming features
    connected_from_features = connected_features
      .select { |f| f.allows_sight_through? && f.allows_sight_from_room?(f.room_id) }
      .map(&:room)
    
    (connected_through_features + connected_from_features).uniq
  end
  
  # Check if this room has a sightline to another room
  def has_sightline_to?(other_room)
    return true if id == other_room.id # Same room
    
    # Check cached sightlines
    sightline = RoomSightline.calculate_sightline(self, other_room)
    sightline.has_sight
  end
  
  # Get sightline quality to another room
  def sightline_quality_to(other_room)
    return 1.0 if id == other_room.id # Same room = perfect sight
    
    sightline = RoomSightline.calculate_sightline(self, other_room)
    sightline.has_sight ? sightline.sight_quality : 0.0
  end
  
  # Get all characters that can be seen from this room across all realities
  # OPTIMIZED: Uses 2 batched queries instead of O(n) queries per visible room
  def visible_characters_across_rooms(viewing_character_instance = nil)
    return [] unless id

    # Query 1: Get all sightlines from this room with positive sight quality
    sightlines = RoomSightline
      .where(from_room_id: id)
      .where { sight_quality > 0 }
      .select_map([:to_room_id, :sight_quality])
      .to_h

    return [] if sightlines.empty?

    # Query 2: Get all characters in those rooms with JOIN (not separate eager query)
    # Using Sequel.case for safe parameterized CASE expression (no SQL injection risk)
    case_conditions = sightlines.map do |room_id, quality|
      [{ Sequel[:character_instances][:current_room_id] => room_id }, quality]
    end
    case_expr = Sequel.case(case_conditions, 0)

    query = CharacterInstance
      .select_all(:character_instances)
      .select_append(case_expr.as(:sightline_quality))
      .select_append(Sequel.as(1, :room_distance))
      .where(current_room_id: sightlines.keys)
      .where(status: 'alive')
      .join(:characters, id: :character_id)
      .select_append(Sequel[:characters][:name].as(:character_name))
      .select_append(Sequel[:characters][:forename].as(:character_forename))
      .select_append(Sequel[:characters][:surname].as(:character_surname))

    # Filter by viewing character if provided
    if viewing_character_instance
      query = query
        .where(reality_id: viewing_character_instance.reality_id)
        .exclude(Sequel[:character_instances][:id] => viewing_character_instance.id)
    end

    query.all
  end
  
  # Calculate if a character at given coordinates can see another character in a different room
  def can_see_character_in_room?(viewer_x, viewer_y, viewer_z, target_room, target_x, target_y, target_z)
    return false unless has_sightline_to?(target_room)
    
    # Find the feature(s) that provide the sightline
    connecting_features = room_features.select do |feature|
      feature.connected_room_id == target_room.id && 
      feature.allows_sight_through? &&
      feature.can_see_from_position?(viewer_x, viewer_y, viewer_z)
    end
    
    # Also check features from the target room to this room
    reverse_features = target_room.room_features.select do |feature|
      feature.connected_room_id == id && 
      feature.allows_sight_through? &&
      feature.allows_sight_from_room?(target_room.id)
    end
    
    connecting_features += reverse_features
    
    return false if connecting_features.empty?
    
    # Check if any connecting feature allows the sight
    connecting_features.any? do |feature|
      # Calculate if the target position is visible through this feature
      # This is a simplified calculation - could be enhanced with proper line-of-sight algorithms
      feature_distance_to_viewer = Math.sqrt((viewer_x - feature.x)**2 + (viewer_y - feature.y)**2 + (viewer_z - feature.z)**2)
      feature_distance_to_target = Math.sqrt((target_x - feature.x)**2 + (target_y - feature.y)**2 + (target_z - feature.z)**2)
      
      total_distance = feature_distance_to_viewer + feature_distance_to_target
      sightline = RoomSightline.calculate_sightline(self, target_room)
      
      sightline.allows_sight_between?(viewer_x, viewer_y, viewer_z, target_x, target_y, target_z)
    end
  end
  
  # === ROOM HEX DETAIL METHODS ===
  
  # Get detailed hex information within this room
  def hex_details(hex_x, hex_y)
    RoomHex.hex_details(self, hex_x, hex_y)
  end
  
  # Get hex type for a position in this room (with default)
  def hex_type(hex_x, hex_y)
    RoomHex.hex_type_at(self, hex_x, hex_y)
  end
  
  # Check if hex is traversable within this room
  def hex_traversable?(hex_x, hex_y)
    RoomHex.traversable_at?(self, hex_x, hex_y)
  end
  
  # Get danger level for a hex in this room
  def hex_danger_level(hex_x, hex_y)
    RoomHex.danger_level_at(self, hex_x, hex_y)
  end
  
  # Check if hex is dangerous
  def hex_dangerous?(hex_x, hex_y)
    RoomHex.dangerous_at?(self, hex_x, hex_y)
  end
  
  # Set hex details (creates or updates hex data)
  def set_hex_details(hex_x, hex_y, attributes = {})
    RoomHex.set_hex_details(self, hex_x, hex_y, attributes)
  end
  
  # Get movement cost for a hex in this room
  def hex_movement_cost(hex_x, hex_y)
    hex_details = hex_details(hex_x, hex_y)
    hex_details ? hex_details.movement_cost : 1
  end
  
  # Get all dangerous hexes in this room
  def dangerous_hexes
    RoomHex.dangerous_hexes_in_room(self)
  end
  
  # Get all impassable hexes in this room
  def impassable_hexes
    RoomHex.impassable_hexes_in_room(self)
  end

  # ========================================
  # Spawn Room Lookup
  # ========================================

  # Find the tutorial spawn room (where new characters start).
  # Uses the tutorial_spawn_room_id GameSetting, with fallbacks.
  def self.tutorial_spawn_room
    configured_id = GameSetting.integer('tutorial_spawn_room_id')
    room = Room[configured_id] if configured_id
    room || Room.first(safe_room: true) || Room.first(room_type: 'safe') || Room.first
  end

  # ========================================
  # Battle Map Methods
  # ========================================

  # Get battle map configuration for this room type
  # @return [Hash] configuration hash with surfaces, objects, density, etc.
  def battle_map_config_for_type
    RoomTypeConfig.battle_map(room_type)
  end

  # Get all cover hexes in this room
  # @return [Sequel::Dataset]
  def cover_hexes
    RoomHex.cover_hexes_in_room(self)
  end

  # Get all explosive hexes in this room
  # @return [Sequel::Dataset]
  def explosive_hexes
    RoomHex.explosive_hexes_in_room(self)
  end

  # Get hex elevation at a position
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [Integer]
  def hex_elevation_at(hex_x, hex_y)
    RoomHex.elevation_at(self, hex_x, hex_y)
  end

  # Get all hexes at a specific elevation
  # @param elevation [Integer]
  # @return [Sequel::Dataset]
  def hexes_at_elevation(elevation)
    RoomHex.hexes_at_elevation(self, elevation)
  end

  # Check if this room has a battle map configured
  # @return [Boolean]
  def battle_map_ready?
    !!has_battle_map && room_hexes_dataset.any?
  end

  # Get room category for battle map generation
  # @return [Symbol] :indoor, :outdoor, or :underground
  def battle_map_category
    RoomTypeConfig.environment(room_type)
  end

  # Environment type for weather, status bar, and UI purposes.
  # Consistent with outdoor_room? for indoor/outdoor classification,
  # unlike battle_map_category which is purely type-based.
  # Respects is_outdoor/indoors database flags.
  # @return [Symbol] :indoor, :outdoor, or :underground
  def room_environment_type
    return :underground if RoomTypeConfig.underground?(room_type)

    outdoor_room? ? :outdoor : :indoor
  end

  # Force underground-style ambient treatment in lighting/effects.
  # Used by dynamic lighting + battle map effects so underground/delve
  # spaces always render with indoor nighttime ambience.
  # @return [Boolean]
  def forced_indoor_night_lighting?
    room_environment_type == :underground || (temporary? && !temp_delve_id.nil?)
  end

  # Check if room type is combat-optimized
  # @return [Boolean]
  def combat_optimized?
    config = battle_map_config_for_type
    !!config[:combat_optimized]
  end

  # Check if room is naturally dark
  # @return [Boolean]
  def naturally_dark?
    config = battle_map_config_for_type
    !!config[:dark]
  end

  # Get parsed battle map configuration JSON
  # @return [Hash]
  def parsed_battle_map_config
    return {} unless battle_map_config

    if battle_map_config.is_a?(Hash)
      battle_map_config
    else
      JSON.parse(battle_map_config.to_s)
    end
  rescue JSON::ParserError
    {}
  end

  # Set battle map configuration
  # @param config [Hash] hex grid settings (hex_size, offset_x, offset_y, etc.)
  def set_battle_map_config!(config)
    update(battle_map_config: Sequel.pg_jsonb_wrap(config))
  end

  # Clear all hex data and reset battle map
  def clear_battle_map!
    room_hexes_dataset.delete
    attrs = {
      has_battle_map: false,
      battle_map_image_url: nil,
      battle_map_config: Sequel.pg_jsonb_wrap({})
    }

    attrs[:battle_map_water_mask_url] = nil if respond_to?(:battle_map_water_mask_url)
    attrs[:battle_map_foliage_mask_url] = nil if respond_to?(:battle_map_foliage_mask_url)
    attrs[:battle_map_fire_mask_url] = nil if respond_to?(:battle_map_fire_mask_url)
    attrs[:battle_map_wall_mask_url] = nil if respond_to?(:battle_map_wall_mask_url)
    attrs[:battle_map_wall_mask_width] = nil if respond_to?(:battle_map_wall_mask_width)
    attrs[:battle_map_wall_mask_height] = nil if respond_to?(:battle_map_wall_mask_height)
    attrs[:detected_light_sources] = Sequel.pg_jsonb_wrap([]) if respond_to?(:detected_light_sources)
    attrs[:depth_map_path] = nil if respond_to?(:depth_map_path)

    update(attrs)
  end

  # Get total hex count in this room
  # @return [Integer]
  def hex_count
    room_hexes_dataset.count
  end

  # Get count of hexes by type
  # @return [Hash] { hex_type => count }
  def hex_type_counts
    room_hexes_dataset.group_and_count(:hex_type).to_hash(:hex_type, :count)
  end

  # Check if coordinates are within room bounds (for hex validation)
  def coordinates_in_bounds?(hex_x, hex_y, hex_z = nil)
    return true unless min_x && max_x && min_y && max_y
    
    x_in_bounds = hex_x >= min_x && hex_x <= max_x
    y_in_bounds = hex_y >= min_y && hex_y <= max_y
    
    z_in_bounds = true
    if hex_z && min_z && max_z
      z_in_bounds = hex_z >= min_z && hex_z <= max_z
    end
    
    x_in_bounds && y_in_bounds && z_in_bounds
  end

  # === ROOM OWNERSHIP METHODS ===

  # Check if a character owns this room
  def owned_by?(character)
    return false unless owner_id && character

    owner_id == character.id
  end

  # Get the "outer" property container (for nested rooms like apartments)
  def outer_room
    inside_room || self
  end

  # Check if a character has access to enter this room
  def unlocked_for?(character)
    return true unless owner_id  # Public room - no owner
    return true if owned_by?(character)  # Owner always has access

    # Check for character-specific unlock
    if room_unlocks_dataset.where(character_id: character.id).where {
         (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP)
       }.any?
      return true
    end

    # Check for group-based unlock (clan access)
    if defined?(GroupRoomUnlock) && defined?(GroupMember)
      character_group_ids = GroupMember.where(character_id: character.id, status: 'active')
                                       .select_map(:group_id)
      if character_group_ids.any?
        if GroupRoomUnlock.where(room_id: id, group_id: character_group_ids)
                          .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                          .any?
          return true
        end
      end
    end

    # Check for public unlock (guest access)
    room_unlocks_dataset.where(character_id: nil).where {
      (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP)
    }.any?
  end

  # Check if room is locked (owned room with no public access)
  def locked?
    return false unless owner_id  # Public rooms are never "locked"

    # Check if there are any public unlocks (guest access)
    !room_unlocks_dataset.where(character_id: nil).where {
      (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP)
    }.any?
  end

  # Lock all public unlocks (remove guest access)
  def lock_doors!
    room_unlocks_dataset.where(character_id: nil).delete
  end

  # Create a public unlock with optional expiration
  def unlock_doors!(expires_in_minutes: nil)
    expires_at = expires_in_minutes ? Time.now + (expires_in_minutes * 60) : nil
    RoomUnlock.create(room_id: id, character_id: nil, expires_at: expires_at)
  end

  # Grant access to a specific character
  def grant_access!(character, permanent: false)
    RoomUnlock.create(
      room_id: id,
      character_id: character.id,
      expires_at: permanent ? nil : Time.now + (24 * 60 * 60)  # Default 24 hours
    )
  end

  # Revoke access from a specific character
  def revoke_access!(character)
    room_unlocks_dataset.where(character_id: character.id).delete
  end

  # Clean up all associated contents of this room before deletion
  # This handles the cascade of dependent records
  def cleanup_contents!
    decorations_dataset.delete
    graffiti_dataset.delete
    places_dataset.delete
    room_features_dataset.delete
    room_unlocks_dataset.delete
    objects_dataset.delete

    # Delete shop and its items if present
    if shop
      shop.shop_items_dataset.delete
      shop.delete
    end
  end

  # === ROOM CUSTOMIZATION METHODS ===

  # Toggle curtains (window opacity)
  def toggle_curtains!
    update(curtains: !curtains)
  end

  # Set default background picture URL
  def set_background!(url)
    update(default_background_url: url)
  end

  # Clear all graffiti from the room
  def clear_graffiti!
    graffiti_dataset.delete
  end

  # Get visible graffiti ordered by creation time
  def visible_graffiti
    graffiti_dataset.order(:created_at)
  end

  # === VAULT ACCESS METHODS ===

  # Check if a character can access vault storage in this room
  def vault_accessible?(character)
    owned_by?(character) || !!is_vault
  end

  # ========================================
  # Private Mode (Staff Vision Exclusion)
  # ========================================

  # Check if room is in private mode (excludes staff vision)
  # @return [Boolean]
  def private_mode?
    !!private_mode
  end

  # Enable private mode - staff vision broadcasts will not include this room
  def enable_private_mode!
    update(private_mode: true)
  end

  # Disable private mode - normal staff vision broadcasting resumes
  def disable_private_mode!
    update(private_mode: false)
  end

  # Toggle private mode
  def toggle_private_mode!
    update(private_mode: !private_mode?)
  end

  # Check if this room should exclude staff vision broadcasts
  # (Alias for private_mode? for semantic clarity in broadcast logic)
  # @return [Boolean]
  def excludes_staff_vision?
    private_mode?
  end

  # ========================================
  # Auto-GM Session Methods
  # ========================================

  # Get active Auto-GM sessions that started in this room
  # @return [Array<AutoGmSession>]
  def active_auto_gm_sessions_started_here
    AutoGmSession.active.where(starting_room_id: id).all
  end

  # Get active Auto-GM sessions currently taking place in this room
  # @return [Array<AutoGmSession>]
  def active_auto_gm_sessions_here
    AutoGmSession.in_room(self).all
  end

  # Check if there's an active Auto-GM session in this room
  # @return [Boolean]
  def has_auto_gm_session?
    AutoGmSession.in_room(self).any?
  end
  alias auto_gm_session? has_auto_gm_session?

  # ========================================
  # Room Publicity Methods
  # ========================================

  # Check if this room is secluded (private, not visible to outsiders)
  # @return [Boolean]
  def secluded?
    publicity == 'secluded'
  end

  # Check if this room is semi-public (limited visibility/access)
  # @return [Boolean]
  def semi_public?
    publicity == 'semi_public'
  end

  # Check if this room is fully public
  # @return [Boolean]
  def public_space?
    publicity.nil? || publicity == 'public'
  end

  # Get the publicity level, defaulting to 'public' if not set
  # @return [String]
  def publicity_level
    publicity || 'public'
  end

  # Set the publicity level
  # @param level [String] one of: 'secluded', 'semi_public', 'public'
  def set_publicity!(level)
    raise ArgumentError, "Invalid publicity level: #{level}" unless PUBLICITY_LEVELS.include?(level)

    update(publicity: level)
  end

  # ========================================
  # System Room Methods
  # ========================================

  # Check if this is a staff-only room
  # @return [Boolean]
  def staff_only?
    !!staff_only
  end

  # Check if this is a death room (no IC communication)
  # @return [Boolean]
  def death_room?
    room_type == 'death'
  end

  # Check if IC communication is blocked in this room
  # @return [Boolean]
  def blocks_ic_communication?
    !!no_ic_communication || death_room?
  end

  # ========================================
  # Seasonal Description and Background Methods
  # ========================================

  # Get description for current time/season with fallback chain
  # Fallback order: specific → same time any season → any time same season → default → base description → parent
  # @param loc [Location, nil] optional location override (defaults to room's location)
  # @return [String]
  def current_description(loc = nil)
    loc ||= location
    time = GameTimeService.time_of_day(loc)
    detail = GameTimeService.season_detail(loc)

    resolve_seasonal_content(seasonal_descriptions, time, detail[:raw_season], mapped_season: detail[:season]) ||
      description ||  # Existing short/long description fallback
      loc&.resolve_description(time, detail[:raw_season]) ||
      loc&.zone&.resolve_description(time, detail[:raw_season]) ||
      short_description
  end

  # Get background URL for current time/season with fallback chain
  # @param loc [Location, nil] optional location override (defaults to room's location)
  # @return [String, nil]
  def current_background_url(loc = nil)
    loc ||= location
    time = GameTimeService.time_of_day(loc)
    detail = GameTimeService.season_detail(loc)

    resolve_seasonal_content(seasonal_backgrounds, time, detail[:raw_season], mapped_season: detail[:season]) ||
      default_background_url ||
      loc&.resolve_background(time, detail[:raw_season]) ||
      loc&.zone&.resolve_background(time, detail[:raw_season])
  end

  # set_seasonal_description!, set_seasonal_background!,
  # clear_seasonal_description!, clear_seasonal_background!,
  # list_seasonal_descriptions, list_seasonal_backgrounds,
  # resolve_description, resolve_background
  # are provided by SeasonalContent concern

  # Legacy compatibility: alias for default_background_url
  alias_method :background_picture_url, :default_background_url

  # ========================================
  # Navigation Helpers (Law of Demeter)
  # ========================================

  # Get the zone this room belongs to
  # @return [Zone, nil]
  def zone
    location&.zone
  end

  # Backward compatibility alias
  alias_method :area, :zone

  # Get the world this room belongs to
  # @return [World, nil]
  def world
    area&.world
  end

  # Get the universe this room belongs to
  # @return [Universe, nil]
  def universe
    world&.universe
  end

  # ========================================
  # Indoor/Outdoor Methods
  # ========================================

  # Check if this is an outdoor room (connects freely to adjacent outdoor rooms).
  # Canonical method - services should delegate to this rather than maintaining
  # their own outdoor-type lists.
  #
  # A room is considered outdoor if:
  # - The is_outdoor flag is explicitly set to true
  # - The indoors flag is explicitly set to false
  # - The room_type belongs to an outdoor category (outdoor_urban, outdoor_nature, water)
  # - The room_type is a street/avenue/intersection (city infrastructure open to sky)
  #
  # @return [Boolean]
  def outdoor_room?
    return true if !!is_outdoor
    return true if !indoors

    RoomTypeConfig.outdoor?(room_type)
  end

  # ========================================
  # Zone Polygon Boundary Methods
  # ========================================

  # Check if room is navigable (inside zone polygon and active)
  # Used to filter exits and prevent movement to inaccessible areas
  # @return [Boolean]
  def navigable?
    !outside_polygon && (active != false)
  end

  # Room center X coordinate (for polygon containment checks)
  # @return [Float]
  def center_x
    (min_x.to_f + max_x.to_f) / 2.0
  end

  # Room center Y coordinate (for polygon containment checks)
  # @return [Float]
  def center_y
    (min_y.to_f + max_y.to_f) / 2.0
  end

  # Calculate if room center is inside zone's polygon boundary
  # @return [Boolean] true if inside polygon (or no polygon defined)
  def inside_zone_polygon?
    return true unless location
    location.city_point_in_zone?(center_x, center_y)
  end

  # Update outside_polygon flag based on zone's polygon boundary
  # Call this when zone polygon changes or after city generation
  # @return [Boolean] the new outside_polygon value
  def recalculate_polygon_status!
    new_status = !inside_zone_polygon?
    update(outside_polygon: new_status) if outside_polygon != new_status
    new_status
  end

  # Get exits filtered to only navigable destination rooms
  # Uses spatial adjacency - rooms connect based on shared polygon edges
  # @return [Array<Hash>] array of { direction:, room: } for navigable exits
  def navigable_exits
    passable_spatial_exits
  end

  # ========================================
  # Custom Room Polygon Methods
  # ========================================

  # Does this room use a custom polygon shape?
  # @return [Boolean]
  def has_custom_polygon?
    rp = room_polygon
    !!(rp && rp.is_a?(Array) && rp.size >= 3)
  end
  alias custom_polygon? has_custom_polygon?

  # Get the shape polygon (custom room polygon or rectangular bounds)
  # This represents the room's intended shape before zone clipping
  # @return [Array<Hash>] array of {x:, y:} points
  def shape_polygon
    if has_custom_polygon?
      room_polygon.map { |p| { 'x' => (p['x'] || p[:x]).to_f, 'y' => (p['y'] || p[:y]).to_f } }
    else
      [
        { 'x' => min_x.to_f, 'y' => min_y.to_f },
        { 'x' => max_x.to_f, 'y' => min_y.to_f },
        { 'x' => max_x.to_f, 'y' => max_y.to_f },
        { 'x' => min_x.to_f, 'y' => max_y.to_f }
      ]
    end
  end

  # Calculate bounding box from polygon (for hex grid sizing)
  # @return [Hash] { min_x:, max_x:, min_y:, max_y: }
  def polygon_bounds
    poly = shape_polygon
    return { min_x: min_x.to_f, max_x: max_x.to_f, min_y: min_y.to_f, max_y: max_y.to_f } unless poly&.any?

    xs = poly.map { |p| (p['x'] || p[:x]).to_f }
    ys = poly.map { |p| (p['y'] || p[:y]).to_f }

    { min_x: xs.min, max_x: xs.max, min_y: ys.min, max_y: ys.max }
  end

  # ========================================
  # Effective Polygon Methods (Zone Clipping)
  # ========================================

  # Get usable polygon (accounting for both custom shape AND zone clipping)
  # Priority: effective_polygon (zone-clipped) > shape_polygon
  # @return [Array<Hash>] array of {x:, y:} points defining usable area
  def usable_polygon
    ep = effective_polygon
    if ep && !ep.empty?
      ep
    else
      shape_polygon
    end
  end

  # Check if position is within usable area
  # @param x [Float] x coordinate in feet
  # @param y [Float] y coordinate in feet
  # @return [Boolean]
  def position_valid?(x, y)
    PolygonClippingService.point_in_effective_area?(self, x, y)
  end

  # Get valid position nearest to requested position
  # @param x [Float] requested x coordinate
  # @param y [Float] requested y coordinate
  # @return [Hash] { x:, y: } closest valid position
  def nearest_valid_position(x, y)
    PolygonClippingService.nearest_valid_position(self, x, y)
  end

  # Is this room clipped by zone polygon?
  # @return [Boolean]
  def is_clipped?
    !effective_polygon.nil? && !effective_polygon.empty?
  end

  # Get area of usable space in square feet
  # @return [Float]
  def usable_area
    effective_area || area_square_feet
  end

  # Get full room area in square feet
  # @return [Float]
  def area_square_feet
    (max_x.to_f - min_x.to_f) * (max_y.to_f - min_y.to_f)
  end

  # Recalculate effective polygon from zone boundary
  # Uses clip_polygon_to_zone if room has custom polygon, otherwise clip_room_to_zone
  # Call this when zone polygon changes or room polygon is updated
  # @return [Boolean] true if room has usable area, false if wholly outside
  def recalculate_effective_polygon!
    result = if has_custom_polygon?
      PolygonClippingService.clip_polygon_to_zone(self)
    else
      PolygonClippingService.clip_room_to_zone(self)
    end

    if result.nil?
      # Room wholly outside polygon - caller should delete this room
      false
    else
      update(
        effective_polygon: result[:polygon] ? Sequel.pg_jsonb_wrap(result[:polygon]) : nil,
        effective_area: result[:area],
        usable_percentage: result[:percentage]
      )
      true
    end
  end

  # Clear effective polygon (reset to full room bounds)
  def clear_effective_polygon!
    update(
      effective_polygon: nil,
      effective_area: nil,
      usable_percentage: 1.0
    )
  end

  # Dataset scopes for polygon filtering
  dataset_module do
    # Filter to only navigable rooms (inside polygon and active)
    def navigable
      where(outside_polygon: false).exclude(active: false)
    end

    # Filter to rooms inside the zone polygon
    def inside_polygon
      where(outside_polygon: false)
    end

    # Filter to rooms outside the zone polygon
    def outside_polygon_scope
      where(outside_polygon: true)
    end

    # Filter to rooms that are clipped (have effective_polygon set)
    def clipped
      exclude(effective_polygon: nil)
    end

    # Filter to rooms with usable area greater than threshold
    def with_usable_area(min_percentage = 0.0)
      where { usable_percentage > min_percentage }
    end
  end

  # ========================================
  # Temporary Room Pool Methods
  # ========================================

  # Associations for temporary rooms
  many_to_one :room_template
  many_to_one :temp_vehicle, class: :Vehicle, key: :temp_vehicle_id
  many_to_one :temp_journey, class: :WorldJourney, key: :temp_journey_id
  many_to_one :temp_delve, class: :Delve, key: :temp_delve_id

  # Check if this is a temporary/pooled room
  # @return [Boolean]
  def temporary?
    !!is_temporary
  end

  # Check if this room is available in the pool
  # @return [Boolean]
  def in_pool?
    temporary? && pool_status == 'available'
  end

  # Check if this room is currently in use
  # @return [Boolean]
  def in_use?
    temporary? && pool_status == 'in_use'
  end

  # Get the vehicle associated with this temporary room (if any)
  # @return [Vehicle, nil]
  def associated_vehicle
    return nil unless temp_vehicle_id

    temp_vehicle
  end

  # Get the world journey associated with this temporary room (if any)
  # @return [WorldJourney, nil]
  def associated_journey
    return nil unless temp_journey_id

    temp_journey
  end

  # Check if this room has custom interior modifications
  # @return [Boolean]
  def has_custom_interior?
    !!has_custom_interior
  end
  alias custom_interior? has_custom_interior?

  # Get the context description for a temporary room
  # This adjusts the description based on what the room is being used for
  # @return [String]
  def temporary_room_description
    if associated_journey
      journey = associated_journey
      destination = journey.respond_to?(:destination_location) ? journey.destination_location&.name : nil
      "Traveling to #{destination || 'your destination'}"
    elsif associated_vehicle
      vehicle = associated_vehicle
      "Inside #{vehicle.respond_to?(:name) ? vehicle.name : 'the vehicle'}"
    else
      desc = short_description
      (desc.nil? || desc.empty?) ? 'A temporary space' : desc
    end
  end

  # Override current_description for temporary rooms to include context
  alias_method :original_current_description, :current_description
  def current_description(loc = nil)
    if temporary? && in_use?
      # For journey rooms, provide dynamic description
      if associated_journey
        journey = associated_journey
        terrain_desc = journey.respond_to?(:terrain_description) ? journey.terrain_description : 'the passing landscape'
        vehicle_desc = journey.respond_to?(:vehicle_description) ? journey.vehicle_description : "A #{journey.vehicle_type || 'vehicle'}"
        return "#{vehicle_desc}.\n\nOutside, you can see #{terrain_desc}."
      end
    end

    # Fall back to original behavior
    original_current_description(loc)
  end

end
