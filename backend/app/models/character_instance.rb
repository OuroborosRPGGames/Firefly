# frozen_string_literal: true

require_relative 'concerns/boolean_helpers'

class CharacterInstance < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  plugin :dirty

  include BooleanHelpers

  # Boolean predicates using shared concern
  boolean_predicate :afk
  boolean_predicate :semiafk
  boolean_predicate :event_camera
  boolean_predicate :creator_mode
  boolean_predicate :minimap
  boolean_predicate :checked_in
  boolean_predicate :invisible
  boolean_predicate :staff_vision_enabled
  boolean_predicate :tts_enabled
  boolean_predicate :tts_paused
  boolean_predicate :is_helpless, :helpless
  boolean_predicate :hands_bound
  boolean_predicate :feet_bound
  boolean_predicate :is_gagged, :gagged
  boolean_predicate :is_blindfolded, :blindfolded
  boolean_predicate :flashback_instanced

  # Boolean toggles
  boolean_toggle :private_mode
  
  many_to_one :character
  many_to_one :reality
  many_to_one :current_room, class: :Room
  many_to_one :current_shape, class: :CharacterShape
  many_to_one :current_place, class: :Place
  many_to_one :current_vehicle, class: :Vehicle
  many_to_one :last_nontemporary_room, class: :Room, key: :last_nontemporary_room_id
  many_to_one :observing, class: :CharacterInstance, key: :observing_id
  one_to_many :observers, class: :CharacterInstance, key: :observing_id
  many_to_one :reading_mind, class: :CharacterInstance, key: :reading_mind_id
  many_to_one :attempt_target, class: :CharacterInstance, key: :attempt_target_id
  many_to_one :pending_attempter, class: :CharacterInstance, key: :pending_attempter_id
  one_to_many :objects, class: :Item
  one_to_many :character_descriptions
  one_to_many :sent_messages, class: :Message, key: :character_instance_id
  one_to_many :received_messages, class: :Message, key: :target_character_instance_id
  one_to_many :character_abilities
  one_to_many :character_stats
  one_to_many :wallets
  one_to_many :outfits
  one_to_many :delve_participants
  many_to_one :current_deck, class: :Deck, key: :current_deck_id
  one_to_many :dealt_decks, class: :Deck, key: :dealer_id
  many_to_one :eating_item, class: :Item, key: :eating_id
  many_to_one :drinking_item, class: :Item, key: :drinking_id
  many_to_one :smoking_item, class: :Item, key: :smoking_id
  many_to_one :creator_from_room, class: :Room, key: :creator_from_room_id
  many_to_one :in_event, class: :Event, key: :in_event_id
  many_to_one :current_world_journey, class: :WorldJourney, key: :current_world_journey_id
  one_to_many :rp_logs
  one_to_many :log_breakpoints

  # Prisoner/Restraint system associations
  many_to_one :being_dragged_by, class: :CharacterInstance, key: :being_dragged_by_id
  many_to_one :being_carried_by, class: :CharacterInstance, key: :being_carried_by_id
  one_to_many :dragging, class: :CharacterInstance, key: :being_dragged_by_id
  one_to_many :carrying, class: :CharacterInstance, key: :being_carried_by_id

  # Timeline system associations
  many_to_one :timeline
  many_to_one :source_snapshot, class: :CharacterSnapshot, key: :source_snapshot_id

  # ========================================
  # Dataset Methods (Scopes)
  # ========================================
  # Common query patterns shared across services

  dataset_module do
    # Online characters with character association eager-loaded
    def online
      where(online: true).eager(:character)
    end

    # Characters in a specific room
    def in_room(room_id)
      where(current_room_id: room_id).online
    end

    # Characters in a room, excluding specific IDs
    def in_room_excluding(room_id, exclude_ids = [])
      exclude_ids = Array(exclude_ids)
      query = in_room(room_id)
      query = query.exclude(id: exclude_ids) if exclude_ids.any?
      query
    end

    # Characters with staff vision enabled (for admin broadcasts)
    def with_staff_vision
      where(online: true, staff_vision_enabled: true).eager(:character)
    end

    # Characters following a specific leader
    def following(leader_id)
      where(following_id: leader_id, online: true).eager(:character)
    end

    # Active characters (for activity tracking)
    def active(minutes_ago: GameConfig::Timeouts::ACTIVITY_TIMEOUT_MINUTES)
      activity_cutoff = Time.now - (minutes_ago * GameConfig::Timeouts::SECONDS_PER_MINUTE)
      where(online: true, activity_tracking_enabled: true)
        .where { last_activity > activity_cutoff }
        .eager(:character)
    end

    # Characters who can be targeted (online and conscious)
    def targetable
      where(online: true).where(status: 'alive').eager(:character)
    end
  end

  # Boolean accessor for show_private_logs (needed by RpLoggingService)
  def show_private_logs?
    show_private_logs == true
  end

  def validate
    super
    # Set defaults before validation
    self.status ||= 'alive'
    self.level ||= 1
    self.experience ||= 0
    self.max_health ||= GameConfig::Mechanics::DEFAULT_HP[:max]
    self.health ||= max_health
    self.max_mana ||= 50
    self.mana ||= max_mana

    validates_presence [:character_id, :reality_id, :current_room_id]
    validates_unique [:character_id, :reality_id]
    validates_integer :level, range: GameConfig::Character::LEVEL_RANGE
    validates_integer :experience, minimum: 0
    validates_integer :health, minimum: 0
    validates_integer :max_health, minimum: 1
    validates_integer :mana, minimum: 0
    validates_integer :max_mana, minimum: 0
    validates_includes ['alive', 'unconscious', 'dead', 'ghost'], :status
    validates_includes %w[standing sitting lying reclining], :stance if stance
  end

  STANCES = %w[standing sitting lying reclining].freeze
  
  def before_save
    super
    # Set defaults
    self.status ||= 'alive'
    self.stance ||= 'standing'
    self.level ||= 1
    self.experience ||= 0
    self.health ||= max_health || GameConfig::Mechanics::DEFAULT_HP[:max]
    self.max_health ||= GameConfig::Mechanics::DEFAULT_HP[:max]
    self.mana ||= max_mana || 50
    self.max_mana ||= 50
    
    # Ensure health doesn't exceed max_health
    self.health = [health, max_health].min if health && max_health
    # Ensure mana doesn't exceed max_mana
    self.mana = [mana, max_mana].min if mana && max_mana
    
    # Update last_activity when online status changes to true
    self.last_activity = Time.now if online && (new? || changed_columns.include?(:online))

    # Track if character is coming online (for after_save hook)
    @coming_online = online && changed_columns.include?(:online)

    # Track room changes for observe refresh (mark dirty rooms before save)
    @observe_dirty_rooms = []
    if !new? && (changed_columns.include?(:current_room_id) ||
                 changed_columns.include?(:current_place_id) ||
                 changed_columns.include?(:stance) ||
                 changed_columns.include?(:online))
      @observe_dirty_rooms << current_room_id if current_room_id
      # If room changed, also mark the old room dirty
      if changed_columns.include?(:current_room_id)
        old_room_id = initial_value(:current_room_id)
        @observe_dirty_rooms << old_room_id if old_room_id
      end
    end

    # Track last non-temporary room as fallback for stranded character rescue
    if changed_columns.include?(:current_room_id)
      old_room_id = initial_value(:current_room_id)
      new_room = Room[current_room_id]
      if new_room&.temporary? && old_room_id
        old_room = Room[old_room_id]
        if old_room && !old_room.temporary?
          self.last_nontemporary_room_id = old_room_id
        end
      end
    end

    # Track when character goes offline for HP restoration on next login
    if !online && changed_columns.include?(:online)
      self.last_logout_at = Time.now
    end

    # Ensure card arrays are properly wrapped as PostgreSQL integer arrays
    if cards_faceup.nil?
      self.cards_faceup = Sequel.pg_array([], :integer)
    elsif !cards_faceup.is_a?(Sequel::Postgres::PGArray)
      self.cards_faceup = Sequel.pg_array(Array(cards_faceup), :integer)
    end
    if cards_facedown.nil?
      self.cards_facedown = Sequel.pg_array([], :integer)
    elsif !cards_facedown.is_a?(Sequel::Postgres::PGArray)
      self.cards_facedown = Sequel.pg_array(Array(cards_facedown), :integer)
    end
  end

  def after_create
    super
    initialize_stats_from_character
  rescue StandardError => e
    warn "[CharacterInstance] Failed to initialize stats: #{e.message}"
  end

  def after_save
    super
    # When a character comes online, create fight entry delay records for active fights
    if @coming_online
      FightEntryDelayService.create_delays_for_character(self)

      # Restore HP to full if offline for 6+ hours
      restore_hp_after_extended_offline!

      # Deliver any pending direct messages and OOC messages
      deliver_pending_direct_messages!
      deliver_pending_ooc_messages!

      @coming_online = false
    end

    # Mark dirty rooms for observe refresh after state changes
    if @observe_dirty_rooms&.any?
      @observe_dirty_rooms.uniq.each { |rid| ObserveRefreshService.mark_room_dirty(rid) }
      @observe_dirty_rooms = nil
    end
  end

  # Deliver pending direct messages when character comes online
  # Uses DirectMessageService to handle delivery
  def deliver_pending_direct_messages!
    return unless defined?(DirectMessageService)

    DirectMessageService.deliver_pending(self)
  rescue StandardError => e
    warn "[CharacterInstance] Failed to deliver pending DMs: #{e.message}"
  end

  # Deliver pending OOC messages when character comes online
  # Uses OocMessageService to handle delivery
  def deliver_pending_ooc_messages!
    return unless defined?(OocMessageService)

    user = character&.user
    return unless user

    OocMessageService.deliver_pending(user)
  rescue StandardError => e
    warn "[CharacterInstance] Failed to deliver pending OOC messages: #{e.message}"
  end

  # Minimum offline time (6 hours) before HP is restored on login
  OFFLINE_HP_RESTORE_HOURS = 6

  # Restore HP to full if character was offline for 6+ hours
  # Called during login via after_save hook
  def restore_hp_after_extended_offline!
    return unless last_logout_at
    return if health.nil? || max_health.nil?
    return if health >= max_health # Already at full HP

    hours_offline = (Time.now - last_logout_at) / 3600.0
    return unless hours_offline >= OFFLINE_HP_RESTORE_HOURS

    # Restore HP without triggering another save cycle
    # Use this.update to bypass callbacks
    self.this.update(health: max_health)
    refresh
  end

  def full_name
    character.full_name
  end

  # Service for managing ability assignment, removal, and queries
  # @return [CharacterAbilityService]
  def ability_service
    @ability_service ||= CharacterAbilityService.new(self)
  end

  # Aliases for consistency with FightParticipant naming
  def current_hp
    health
  end

  def current_hp=(value)
    self.health = value
  end

  def max_hp
    max_health
  end

  def max_hp=(value)
    self.max_health = value
  end

  # Apply direct HP loss to the character instance.
  # Returns the HP actually lost after clamping.
  def take_damage(amount)
    damage = amount.to_i
    return 0 if damage <= 0

    current = health || 0
    new_health = [current - damage, 0].max
    lost = current - new_health

    update(health: new_health)
    lost
  end

  # Delegate unknown methods to the associated Character.
  # This lets code use instance.npc? instead of instance.character.npc?,
  # instance.forename instead of instance.character.forename, etc.
  # CharacterInstance holds session/state; Character holds identity/profile.
  def method_missing(method_name, *args, &block)
    if character&.respond_to?(method_name)
      character.public_send(method_name, *args, &block)
    else
      super
    end
  end

  def respond_to_missing?(method_name, include_private = false)
    character&.respond_to?(method_name) || super
  end

  def is_alive?
    status == 'alive'
  end
  
  def is_conscious?
    ['alive'].include?(status)
  end
  
  def can_act?
    is_conscious? && online
  end

  # ========================================
  # Timeline System Methods
  # ========================================

  # Check if this instance is in a past timeline
  def in_past_timeline?
    return false unless timeline_id || is_timeline_instance

    timeline&.past_timeline? || false
  end

  # Check if this character can die (blocked in past timelines)
  def can_die?
    return true unless in_past_timeline?

    !timeline&.no_death?
  end

  # Check if this character can gain XP (blocked in past timelines)
  def can_gain_xp?
    return true unless in_past_timeline?

    !timeline&.no_xp?
  end

  # Check if this character can become a prisoner (blocked in past timelines)
  def can_be_prisoner?
    return true unless in_past_timeline?

    !timeline&.no_prisoner?
  end

  # Check if this instance can modify rooms (blocked in past timelines)
  def can_modify_rooms?
    return true unless in_past_timeline?

    !timeline&.rooms_read_only?
  end

  # Safe experience gain that respects timeline restrictions
  def gain_experience!(amount)
    return false unless can_gain_xp?

    new_exp = (experience || 0) + amount
    update(experience: new_exp)
    true
  end

  # Get timeline display info
  def timeline_display_name
    return nil unless in_past_timeline?

    timeline&.display_name
  end

  # ========================================
  # End Timeline System Methods
  # ========================================

  def equipped_objects
    objects_dataset.where(equipped: true)
  end

  def inventory
    objects_dataset.where(equipped: false, stored: false)
  end
  
  def descriptions_for_display
    character_descriptions_dataset.join(:description_types, id: :description_type_id)
                                  .where(Sequel[:character_descriptions][:active] => true)
                                  .order(Sequel[:description_types][:display_order])
  end

  # Get active body position descriptions (physical appearance - hair, eyes, tattoos, etc.)
  # @return [Sequel::Dataset] Dataset of body position descriptions
  def body_descriptions_for_display
    character_descriptions_dataset
      .exclude(body_position_id: nil)
      .where(active: true)
      .order(:display_order, :id)
  end
  
  def character_description(type_name, mood = nil)
    desc = character_descriptions_dataset.join(:description_types, id: :description_type_id)
                                         .where(Sequel[:description_types][:name] => type_name)
                                         .where(Sequel[:character_descriptions][:active] => true)
    desc = desc.where(mood_context: mood) if mood
    desc.first&.content
  end
  
  def set_description(type_name, content, mood = nil)
    desc_type = DescriptionType.first(name: type_name)
    return false unless desc_type
    
    existing = CharacterDescription.first(
      character_instance_id: id,
      description_type_id: desc_type.id,
      mood_context: mood
    )
    
    if existing
      existing.update(content: content)
    else
      CharacterDescription.create(
        character_instance_id: id,
        description_type_id: desc_type.id,
        content: content,
        mood_context: mood
      )
    end
    true
  end
  
  # Character visibility - can see others in same room/reality or through sightlines
  def can_see?(other_character_instance)
    return false unless other_character_instance.is_a?(CharacterInstance)
    return false unless is_conscious?
    return false unless reality_id == other_character_instance.reality_id
    
    # Same room - always visible (assuming lighting, etc.)
    return true if current_room_id == other_character_instance.current_room_id
    
    # Different rooms - check for sightlines
    return false unless current_room && other_character_instance.current_room
    
    # Check if rooms have sightline connection
    return false unless current_room.has_sightline_to?(other_character_instance.current_room)
    
    # Check position-based line of sight through room features
    my_pos = position
    other_pos = other_character_instance.position
    
    current_room.can_see_character_in_room?(
      my_pos[0], my_pos[1], my_pos[2],
      other_character_instance.current_room,
      other_pos[0], other_pos[1], other_pos[2]
    )
  end
  
  # Get all character instances this character can see (same room + cross-room through sightlines)
  def visible_characters
    return CharacterInstance.where(id: nil) unless current_room_id && reality_id

    visible_chars = []

    # Characters in same room
    same_room_chars = CharacterInstance.where(
      reality_id: reality_id,
      current_room_id: current_room_id,
      status: 'alive'
    ).exclude(id: id)

    visible_chars += same_room_chars.all

    # Characters in connected rooms through sightlines
    if current_room
      cross_room_chars = current_room.visible_characters_across_rooms(self)
      visible_chars += cross_room_chars.reject { |c| c.id == id }
    end

    # Return as dataset-like object for consistency
    CharacterInstance.where(id: visible_chars.map(&:id))
  end
  
  # Get coordinates - interpolated during active movement
  def position
    if movement_state == 'moving'
      interp = interpolated_movement_position
      return interp if interp
    end
    [x || 0.0, y || 0.0, z || 0.0]
  end

  # Raw DB position without movement interpolation
  def db_position
    [x || 0.0, y || 0.0, z || 0.0]
  end

  private

  # Interpolate position along movement path based on elapsed time
  def interpolated_movement_position
    action = TimedAction
      .where(character_instance_id: id, action_name: 'movement', status: 'active')
      .first
    return nil unless action

    data = action.parsed_action_data
    sx = data[:start_x]&.to_f
    sy = data[:start_y]&.to_f
    sz = data[:start_z]&.to_f || 0.0
    tx = data[:target_x]&.to_f
    ty = data[:target_y]&.to_f
    tz = data[:target_z]&.to_f || 0.0
    return nil unless sx && sy && tx && ty

    elapsed = (Time.now - action.started_at).to_f
    total = (action.duration_ms || 1).to_f / 1000.0
    t = (elapsed / total).clamp(0.0, 1.0)

    [sx + (tx - sx) * t, sy + (ty - sy) * t, sz + (tz - sz) * t]
  end

  public
  
  def move_to(new_x, new_y, new_z)
    update(x: new_x, y: new_y, z: new_z)
  end
  
  # Check if character is within room bounds
  def within_room_bounds?
    return true unless current_room

    room = current_room
    current_x, current_y, current_z = position

    current_x >= (room.min_x || 0.0) && current_x <= (room.max_x || 100.0) &&
      current_y >= (room.min_y || 0.0) && current_y <= (room.max_y || 100.0) &&
      current_z >= (room.min_z || 0.0) && current_z <= (room.max_z || 10.0)
  end

  # Check if character position is within usable room area (respects zone polygon clipping)
  # @return [Boolean]
  def within_usable_area?
    return true unless current_room

    current_room.position_valid?(x || 0.0, y || 0.0)
  end

  # Move to a position, validating against effective polygon
  # Returns false if position is outside usable area
  # @param new_x [Float] requested x coordinate
  # @param new_y [Float] requested y coordinate
  # @param new_z [Float, nil] optional z coordinate
  # @param snap_to_valid [Boolean] if true, snaps to nearest valid position instead of failing
  # @return [Boolean] true if move succeeded
  def move_to_valid_position(new_x, new_y, new_z = nil, snap_to_valid: false)
    return false unless current_room

    # Check if requested position is valid
    if current_room.position_valid?(new_x, new_y)
      update(x: new_x, y: new_y, z: new_z || z)
      return true
    end

    # Position is outside usable area
    return false unless snap_to_valid

    # Find nearest valid position
    valid_pos = current_room.nearest_valid_position(new_x, new_y)
    return false unless valid_pos

    update(x: valid_pos[:x], y: valid_pos[:y], z: new_z || z)
    true
  end

  # Snap character to nearest valid position if currently outside usable area
  # @return [Boolean] true if position was adjusted
  def snap_to_valid_position!
    return true if within_usable_area?
    return false unless current_room

    valid_pos = current_room.nearest_valid_position(x || 0.0, y || 0.0)
    return false unless valid_pos

    update(x: valid_pos[:x], y: valid_pos[:y])
    true
  end

  # Teleport character to a room, setting position to center of usable area
  # Use this instead of directly updating current_room_id to ensure valid coordinates
  def teleport_to_room!(room)
    # Calculate center of destination room's usable area
    if room.is_clipped?
      # Use centroid of effective polygon
      valid_pos = room.nearest_valid_position(room.center_x, room.center_y)
      center_x = valid_pos[:x]
      center_y = valid_pos[:y]
    else
      # Standard room center
      center_x = ((room.min_x || 0.0) + (room.max_x || 100.0)) / 2.0
      center_y = ((room.min_y || 0.0) + (room.max_y || 100.0)) / 2.0
    end
    center_z = (room.min_z || 0.0)  # Ground level

    update(
      current_room_id: room.id,
      x: center_x,
      y: center_y,
      z: center_z
    )
  end

  # Get a safe fallback room for stranded character rescue.
  # Returns the last known non-temporary room, or tutorial spawn as last resort.
  # @return [Room]
  def safe_fallback_room
    (last_nontemporary_room_id && Room[last_nontemporary_room_id]) || Room.tutorial_spawn_room
  end

  # Private mode for adult content visibility
  def private_mode?
    private_mode == true
  end

  def toggle_private_mode!
    update(private_mode: !private_mode?)
  end

  def enter_private_mode!
    update(private_mode: true)
  end

  def leave_private_mode!
    update(private_mode: false)
  end

  # Activity status tracking (for status bar)
  # Set a temporary action with optional duration
  # @param text [String] action description ("sitting at the bar")
  # @param duration [Integer, nil] seconds until expiration (nil = no expiration)
  def set_action(text, duration: nil)
    update(
      current_action: text,
      current_action_until: duration ? Time.now + duration : nil
    )
  end

  # Clear the temporary action
  def clear_action
    update(current_action: nil, current_action_until: nil)
  end

  # Get the current display action for status bar
  # @return [String] the action text to display
  def display_action
    if current_action && action_not_expired?
      current_action
    else
      static_action || default_static_action
    end
  end

  # Check if the current temporary action has expired
  def action_not_expired?
    current_action_until.nil? || current_action_until > Time.now
  end

  # Generate default action from stance and location
  def default_static_action
    stance_text = case stance
                  when 'sitting' then 'sitting'
                  when 'lying' then 'lying down'
                  when 'reclining' then 'reclining'
                  else 'standing'
                  end

    place = current_place
    if place
      "#{stance_text} at #{place.name}"
    else
      "#{stance_text} in #{current_room&.name || 'somewhere'}"
    end
  end

  # Items that are worn (clothing, jewelry, etc.)
  def worn_items
    objects_dataset.where(worn: true).order(:display_order, Sequel.desc(:worn_layer))
  end

  # Items held in hands
  def held_items
    # Primary: explicit held flag.
    # Backward compatibility: legacy hand-slot equipped items.
    objects_dataset
      .where(stored: false, transfer_started_at: nil)
      .where(
        Sequel.|(
          { held: true },
          Sequel.&(
            { equipped: true },
            { equipment_slot: %w[left_hand right_hand both_hands] }
          )
        )
      )
  end

  # Items in inventory (not worn, equipped, or holstered)
  def inventory_items
    objects_dataset
      .where(worn: false, equipped: false, holstered_in_id: nil, stored: false)
      .where(transfer_started_at: nil)
  end

  # Items currently in holsters worn by this character
  def holstered_items
    # Get worn holsters (items whose patterns have holster_capacity > 0)
    worn_holster_ids = worn_items
                       .join(:patterns, id: :pattern_id)
                       .where(Sequel.lit('patterns.holster_capacity > 0'))
                       .select_map(Sequel[:objects][:id])
    return Item.where(id: nil) if worn_holster_ids.empty?

    Item.where(holstered_in_id: worn_holster_ids)
  end

  # Piercing system
  # Check if a body position has been pierced
  def pierced_at?(position)
    normalized = position.to_s.downcase.strip
    (piercing_positions || []).any? { |p| p.downcase == normalized }
  end

  # Add a piercing position
  def add_piercing_position!(position)
    normalized = position.to_s.downcase.strip
    return false if pierced_at?(normalized)

    current = piercing_positions || []
    update(piercing_positions: current + [normalized])
    true
  end

  # List all pierced positions
  def pierced_positions
    piercing_positions || []
  end

  # Get piercings worn at a specific position
  def piercings_at(position)
    normalized = position.to_s.downcase.strip
    objects_dataset.where(is_piercing: true, worn: true)
                   .all
                   .select { |item| item.piercing_position&.downcase == normalized }
  end

  # Check if at a place within the room
  def at_place?
    !current_place_id.nil?
  end

  # Move to a place within the room
  def go_to_place(place)
    return false unless place && place.room_id == current_room_id
    return false if place.full?

    update(current_place_id: place.id)
    true
  end

  # Leave current place
  def leave_place!
    update(current_place_id: nil)
  end

  # Stance helpers
  def standing?
    stance == 'standing' || stance.nil?
  end

  def sitting?
    stance == 'sitting'
  end

  def lying?
    stance == 'lying'
  end

  def reclining?
    stance == 'reclining'
  end

  # Change stance
  def sit!
    update(stance: 'sitting')
  end

  def stand!
    update(stance: 'standing', current_place_id: nil)
  end

  def lie_down!
    update(stance: 'lying')
  end

  def recline!
    update(stance: 'reclining')
  end

  # Get current stance or default
  def current_stance
    stance || 'standing'
  end

  # Check if character is in an active fight
  def in_combat?
    FightParticipant.where(character_instance_id: id)
                    .eager(:fight)
                    .all
                    .any? { |p| p.fight&.ongoing? }
  end

  # ========================================
  # Flee System
  # ========================================

  # Association to track which fight this character fled from
  many_to_one :fled_from_fight, class: :Fight, key: :fled_from_fight_id

  # Check if character has fled from a specific fight (cannot re-enter)
  # @param fight [Fight] the fight to check
  # @return [Boolean]
  def has_fled_from_fight?(fight)
    fled_from_fight_id == fight.id
  end

  # Clear fled status (called when fight ends)
  def clear_fled_status!
    update(fled_from_fight_id: nil)
  end

  # Association to track which fight this character surrendered from
  many_to_one :surrendered_from_fight, class: :Fight, key: :surrendered_from_fight_id

  # Check if character has surrendered from a specific fight (cannot re-enter)
  # @param fight [Fight] the fight to check
  # @return [Boolean]
  def has_surrendered_from_fight?(fight)
    surrendered_from_fight_id == fight.id
  end

  # Clear surrendered status (called when fight ends)
  def clear_surrendered_status!
    update(surrendered_from_fight_id: nil)
  end

  # Observation system
  def observing?
    !observing_id.nil? || !observing_place_id.nil? || observing_room == true
  end

  def observing_character?
    !observing_id.nil?
  end

  def observing_place?
    !observing_place_id.nil?
  end

  def observing_room?
    observing_room == true
  end

  def start_observing!(target)
    return false unless target.is_a?(CharacterInstance)

    update(observing_id: target.id, observing_place_id: nil, observing_room: false)
    true
  end

  def start_observing_place!(place)
    return false unless place.is_a?(Place)

    update(observing_id: nil, observing_place_id: place.id, observing_room: false)
    true
  end

  def start_observing_room!
    update(observing_id: nil, observing_place_id: nil, observing_room: true)
    true
  end

  def stop_observing!
    update(observing_id: nil, observing_place_id: nil, observing_room: false)
    true
  end

  # Get the currently observed place
  def observed_place
    return nil unless observing_place_id

    Place[observing_place_id]
  end

  # Get all character instances currently observing this character
  def current_observers
    CharacterInstance.where(observing_id: id, online: true)
  end

  # ===== Presence Status System =====

  # afk? is defined by boolean_predicate :afk

  # Check if character is currently on a world journey
  def traveling?
    !current_world_journey_id.nil?
  end

  # Get current world travel position
  def world_travel_position
    return nil unless traveling?

    journey = current_world_journey
    return nil unless journey

    { globe_hex_id: journey.current_globe_hex_id }
  end

  def set_afk!(minutes = nil)
    if minutes && minutes > 0
      update(afk: true, afk_until: Time.now + (minutes * 60), semiafk: false)
    else
      update(afk: true, afk_until: nil, semiafk: false)
    end
  end

  def clear_afk!
    update(afk: false, afk_until: nil, semiafk: false)
  end

  def afk_expired?
    afk? && afk_until && Time.now > afk_until
  end

  # semiafk? is defined by boolean_predicate :semiafk

  def toggle_semiafk!
    if semiafk?
      self.this.update(semiafk: false, semiafk_until: nil, afk: false)
    else
      self.this.update(semiafk: true, semiafk_until: nil, afk: false, afk_until: nil)
    end
    refresh
  end

  def set_semiafk!(minutes = nil)
    if minutes && minutes > 0
      self.this.update(semiafk: true, semiafk_until: Time.now + (minutes * 60), afk: false, afk_until: nil)
    else
      self.this.update(semiafk: true, semiafk_until: nil, afk: false, afk_until: nil)
    end
    refresh
  end

  def clear_semiafk!
    self.this.update(semiafk: false, semiafk_until: nil)
    refresh
  end

  def semiafk_expired?
    return false unless semiafk? && semiafk_until

    Time.now > semiafk_until
  end

  def gtg?
    gtg_until && Time.now < gtg_until
  end

  def set_gtg!(minutes = 15)
    update(gtg_until: Time.now + (minutes * 60))
  end

  def clear_gtg!
    update(gtg_until: Time.now - (12 * 60 * 60))
  end

  # ===== Quiet Mode =====
  # Hides all channel messages (OOC, global, area, group) while active

  def quiet_mode?
    self[:quiet_mode] == true
  end

  def set_quiet_mode!
    # Use this.update to bypass mass assignment (safe for internal model methods)
    self.this.update(quiet_mode: true, quiet_mode_since: Time.now)
    refresh
  end

  def clear_quiet_mode!
    # Use this.update to bypass mass assignment (safe for internal model methods)
    self.this.update(quiet_mode: false)
    refresh
    # Note: keep quiet_mode_since for catch-up query
  end

  def presence_status
    return 'afk' if afk?
    return 'semiafk' if semiafk?
    return 'gtg' if gtg?
    'present'
  end

  # Build presence indicator for room display
  # Returns nil if no status, or a hash with status, minutes, and until_timestamp
  # @return [Hash, nil] presence indicator data
  def presence_indicator
    return nil unless afk? || semiafk? || gtg?

    if gtg?
      minutes = gtg_until ? ((gtg_until - Time.now) / 60).ceil : nil
      return nil if minutes && minutes <= 0
      { status: 'gtg', minutes: minutes, until_timestamp: gtg_until&.iso8601 }
    elsif afk?
      minutes = afk_until ? ((afk_until - Time.now) / 60).ceil : nil
      return nil if afk_until && minutes && minutes <= 0
      { status: 'afk', minutes: minutes, until_timestamp: afk_until&.iso8601 }
    elsif semiafk?
      minutes = semiafk_until ? ((semiafk_until - Time.now) / 60).ceil : nil
      return nil if semiafk_until && minutes && minutes <= 0
      { status: 'semi-afk', minutes: minutes, until_timestamp: semiafk_until&.iso8601 }
    end
  end

  # ===== Auto-AFK System =====

  # Calculate minutes since last activity
  def inactive_minutes
    return 0 unless last_activity
    ((Time.now - last_activity) / 60).to_i
  end

  # Check if WebSocket connection appears stale
  def websocket_stale?(timeout_minutes = 5)
    return true unless last_websocket_ping
    ((Time.now - last_websocket_ping) / 60) > timeout_minutes
  end

  # Touch the WebSocket ping timestamp
  def touch_websocket_ping!
    update(last_websocket_ping: Time.now)
  end

  # Check if character is alone in their room
  def alone_in_room?
    return true unless current_room_id
    CharacterInstance.where(current_room_id: current_room_id, online: true)
                     .exclude(id: id)
                     .count.zero?
  end

  # Check if character is exempt from auto-AFK
  def auto_afk_exempt?
    auto_afk_exempt == true || character&.staff?
  end

  # Handle automatic logout with cleanup
  def auto_logout!(reason = 'inactivity')
    # Record playtime before logging out
    record_session_playtime!

    # Reset combat and activity state
    reset_combat_and_activities!(end_fights: true)

    # Stop any active following/observing
    update(
      online: false,
      following_id: nil,
      observing_id: nil,
      reading_mind_id: nil,
      checked_in: false,
      afk: false,
      semiafk: false,
      session_start_at: nil
    )

    # Broadcast departure to room (personalized per viewer)
    if current_room_id
      message = "#{character.full_name} has disconnected."

      room_chars = CharacterInstance.where(
        current_room_id: current_room_id,
        online: true
      ).exclude(id: id).eager(:character).all

      room_chars.each do |viewer|
        personalized = MessagePersonalizationService.personalize(
          message: message,
          viewer: viewer,
          room_characters: room_chars + [self]
        )
        BroadcastService.to_character(viewer, personalized)
      end
    end

    warn "[AutoAFK] Logged out #{character.full_name} (reason: #{reason})" if ENV['LOG_AFK']
  end

  # Reset all combat and activity state for clean login/logout
  # Called during agent cleanup or logout to prevent stale state
  #
  # @param end_fights [Boolean] Whether to end any active fights
  # @return [Hash] Summary of what was cleaned up
  def reset_combat_and_activities!(end_fights: true)
    cleaned = { interactions: 0, activities: 0, fights: 0 }

    DB.transaction do
      # Clear pending interactions (quickmenus, forms, etc.)
      if respond_to?(:pending_interactions)
        pending_interactions_dataset.delete
        cleaned[:interactions] += 1
      end

      # Leave any activities
      if respond_to?(:activity_participants)
        activity_participants_dataset.destroy
        cleaned[:activities] += 1
      end

      # End active fights if requested
      if end_fights
        FightParticipant.where(character_instance_id: id).each do |fp|
          fight = fp.fight
          next unless fight && fight.ongoing?

          # Mark participant as knocked out (fight is over for them)
          fp.update(defeated_at: Time.now, is_knocked_out: true)
          cleaned[:fights] += 1

          # If fight has no active participants, end it
          fight.reload
          fight.complete! if fight.active_participants.count == 0
        end
      end

      # Clear movement action state
      update(
        movement_action: nil,
        movement_target_id: nil,
        movement_action_started_at: nil
      ) if respond_to?(:movement_action)
    end

    cleaned
  end

  # ===== Session Tracking =====

  # Start a new session and record the start time
  # Called when character goes online
  #
  # @return [self]
  def start_session!
    update(session_start_at: Time.now)
    self
  end

  # End a session and record playtime to the user
  # Called when character logs out
  #
  # @return [Integer, nil] Session duration in seconds, or nil if no session
  def record_session_playtime!
    return nil unless session_start_at

    session_seconds = (Time.now - session_start_at).to_i
    return nil if session_seconds <= 0

    # Record playtime to user
    character&.user&.increment_playtime!(session_seconds)

    session_seconds
  end

  # Get current session duration in seconds
  #
  # @return [Integer] Session duration, or 0 if no active session
  def current_session_seconds
    return 0 unless session_start_at && online

    (Time.now - session_start_at).to_i
  end

  # ===== Telepathy System =====

  def reading_mind?
    !reading_mind_id.nil?
  end

  def start_reading_mind!(target)
    return false unless target.is_a?(CharacterInstance)

    update(reading_mind_id: target.id)
    true
  end

  def stop_reading_mind!
    update(reading_mind_id: nil)
  end

  def mind_readers
    CharacterInstance.where(reading_mind_id: id, online: true)
  end

  # ===== Attempt/Consent System =====

  def has_pending_attempt?
    !pending_attempter_id.nil? && pending_attempt_text
  end
  alias pending_attempt? has_pending_attempt?

  def submit_attempt!(target, text)
    update(attempt_text: text, attempt_target_id: target.id)
    target.update(
      pending_attempter_id: id,
      pending_attempt_text: text,
      pending_attempt_at: Time.now
    )
  end

  def clear_attempt!
    update(attempt_text: nil, attempt_target_id: nil)
  end

  def clear_pending_attempt!
    update(pending_attempter_id: nil, pending_attempt_text: nil, pending_attempt_at: nil)
  end

  # ===== Pending OOC Request System =====

  many_to_one :pending_ooc_request, class: :OocRequest, key: :pending_ooc_request_id

  def has_pending_ooc_request?
    !pending_ooc_request_id.nil?
  end
  alias pending_ooc_request? has_pending_ooc_request?

  def set_pending_ooc_request!(request)
    update(pending_ooc_request_id: request.id)
  end

  def clear_pending_ooc_request!
    update(pending_ooc_request_id: nil)
  end

  # ===== Card Game System =====

  def in_card_game?
    !current_deck_id.nil?
  end

  def has_cards?
    return false unless cards_faceup || cards_facedown

    (cards_faceup || []).any? || (cards_facedown || []).any?
  end
  alias cards? has_cards?

  def all_card_ids
    (cards_faceup || []) + (cards_facedown || [])
  end

  def card_count
    all_card_ids.length
  end

  def faceup_cards
    return [] unless cards_faceup&.any?

    Card.where(id: cards_faceup.to_a).all
  end

  def facedown_cards
    return [] unless cards_facedown&.any?

    Card.where(id: cards_facedown.to_a).all
  end

  def all_cards
    faceup_cards + facedown_cards
  end

  def add_cards_faceup(card_ids)
    current = Array(cards_faceup)
    new_cards = current + Array(card_ids)
    update(cards_faceup: Sequel.pg_array(new_cards, :integer))
  end

  def add_cards_facedown(card_ids)
    current = Array(cards_facedown)
    new_cards = current + Array(card_ids)
    update(cards_facedown: Sequel.pg_array(new_cards, :integer))
  end

  def clear_cards!
    update(cards_faceup: Sequel.pg_array([], :integer), cards_facedown: Sequel.pg_array([], :integer))
  end

  def leave_card_game!
    clear_cards!
    update(current_deck_id: nil)
  end

  def join_card_game!(deck)
    update(current_deck_id: deck.id)
  end

  # Flip cards from facedown to faceup in hand
  def flip_cards(count = nil)
    facedown_ids = Array(cards_facedown)
    return [] if facedown_ids.empty?

    to_flip = count ? facedown_ids.first(count) : facedown_ids.dup
    remaining_facedown = facedown_ids - to_flip
    new_faceup = Array(cards_faceup) + to_flip

    update(
      cards_facedown: Sequel.pg_array(remaining_facedown, :integer),
      cards_faceup: Sequel.pg_array(new_faceup, :integer)
    )
    to_flip
  end

  # Remove a specific card from hand, returns :faceup, :facedown, or nil
  def remove_card(card_id)
    faceup_ids = Array(cards_faceup)
    facedown_ids = Array(cards_facedown)

    if faceup_ids.include?(card_id)
      update(cards_faceup: Sequel.pg_array(faceup_ids - [card_id], :integer))
      :faceup
    elsif facedown_ids.include?(card_id)
      update(cards_facedown: Sequel.pg_array(facedown_ids - [card_id], :integer))
      :facedown
    end
  end

  # ===== Consumption System =====

  def consuming?
    eating? || drinking? || smoking?
  end

  def eating?
    !eating_id.nil?
  end

  def drinking?
    !drinking_id.nil?
  end

  def smoking?
    !smoking_id.nil?
  end

  def start_eating!(item)
    update(eating_id: item.id)
  end

  def stop_eating!
    update(eating_id: nil)
  end

  def start_drinking!(item)
    update(drinking_id: item.id)
  end

  def stop_drinking!
    update(drinking_id: nil)
  end

  def start_smoking!(item)
    update(smoking_id: item.id)
  end

  def stop_smoking!
    update(smoking_id: nil)
  end

  def stop_consuming!
    update(eating_id: nil, drinking_id: nil, smoking_id: nil)
  end

  # ===== Event Spotlight System =====

  def spotlighted?
    event_camera == true
  end

  def toggle_spotlight!
    if spotlighted?
      spotlight_off!
    else
      spotlight_on!
    end
  end

  # Turn spotlight on, optionally for a specific number of emotes
  # @param count [Integer, nil] number of emotes before auto-disable (nil = unlimited)
  def spotlight_on!(count: nil)
    update(event_camera: true, spotlight_remaining: count)
  end

  def spotlight_off!
    update(event_camera: false, spotlight_remaining: nil)
  end

  # Decrement spotlight counter after an emote
  # - If spotlight_remaining is nil (unlimited/toggle mode): clears spotlight (one-shot)
  # - If spotlight_remaining > 1: decrements counter
  # - If spotlight_remaining <= 1: clears spotlight
  # @return [Boolean] true if spotlight was decremented/disabled, false if not spotlighted
  def decrement_spotlight!
    return false unless spotlighted?

    # If no counter set (unlimited/toggle mode), clear after one use (one-shot)
    if spotlight_remaining.nil?
      spotlight_off!
      return true
    end

    new_count = spotlight_remaining - 1
    if new_count <= 0
      spotlight_off!
    else
      update(spotlight_remaining: new_count)
    end
    true
  end

  # Check if character is exempt from emote rate limiting
  # Exemptions: spotlight, event organizer, event staff
  # @return [Boolean]
  def exempt_from_emote_rate_limit?
    return true if spotlighted?

    # Check if organizer or staff of any active event in current room
    return false unless current_room_id

    events = Event.where(status: 'active')
                  .where(Sequel.or(
                    room_id: current_room_id,
                    location_id: current_room&.location_id
                  ))
                  .all

    events.any? do |event|
      # Check if organizer
      next true if event.organizer_id == character_id

      # Check if host or staff
      attendee = EventAttendee.first(event_id: event.id, character_id: character_id)
      attendee&.staff?
    end
  end

  # ===== Creator/Building Mode =====

  def creator_mode?
    creator_mode == true
  end

  def enter_creator_mode!
    update(
      creator_mode: true,
      creator_from_room_id: current_room_id
    )
  end

  def exit_creator_mode!
    return_room_id = creator_from_room_id
    update(
      creator_mode: false,
      creator_from_room_id: nil
    )
    return_room_id
  end

  # ===== Event Participation System =====

  def in_event?
    !in_event_id.nil?
  end

  def enter_event!(event)
    update(in_event_id: event.id)
  end

  def leave_event!
    update(in_event_id: nil, event_camera: false, spotlight_remaining: nil)
  end

  # Minimap preference
  def minimap_enabled?
    minimap == true
  end

  def toggle_minimap!
    update(minimap: !minimap_enabled?)
    minimap_enabled?
  end

  # ===== Wetness System =====

  def wet?
    (wetness || 0) > 0
  end

  def soaked?
    (wetness || 0) >= 75
  end

  def damp?
    wet? && !soaked?
  end

  def dry?
    !wet?
  end

  def wetness_level
    wetness || 0
  end

  def apply_wetness!(amount = 50)
    new_wetness = [(wetness || 0) + amount, 100].min
    update(wetness: new_wetness)
  end

  def dry_off!
    update(wetness: 0)
  end

  def wetness_description
    level = wetness_level
    case level
    when 0 then 'dry'
    when 1..25 then 'slightly damp'
    when 26..50 then 'damp'
    when 51..75 then 'wet'
    else 'soaked'
    end
  end

  # ===== Check-In System =====

  def checked_in?
    checked_in == true
  end

  def check_in!
    update(
      checked_in: true,
      checked_in_at: Time.now,
      checked_in_room_id: current_room_id
    )
  end

  def check_out!
    update(
      checked_in: false,
      checked_in_at: nil,
      checked_in_room_id: nil
    )
  end

  def checked_in_room
    return nil unless checked_in_room_id

    Room[checked_in_room_id]
  end

  def checked_in_here?
    checked_in? && checked_in_room_id == current_room_id
  end

  # ========================================
  # Staff Visibility System
  # ========================================

  # invisible? is defined by boolean_predicate :invisible

  # Go invisible (hide from player "who" lists and room presence)
  # Requires staff character with can_go_invisible permission
  def go_invisible!
    return false unless character.can_go_invisible?

    update(invisible: true)
    true
  end

  # Become visible again
  def go_visible!
    update(invisible: false)
    true
  end

  # Toggle invisibility
  def toggle_invisible!
    if invisible?
      go_visible!
    else
      go_invisible!
    end
  end

  # staff_vision_enabled? is defined by boolean_predicate :staff_vision_enabled

  # Enable staff vision (receive broadcasts from all non-private rooms)
  # Requires staff character with can_see_all_rp permission
  def enable_staff_vision!
    return false unless character.can_see_all_rp?

    update(staff_vision_enabled: true)
    true
  end

  # Disable staff vision
  def disable_staff_vision!
    update(staff_vision_enabled: false)
    true
  end

  # Toggle staff vision
  def toggle_staff_vision!
    if staff_vision_enabled?
      disable_staff_vision!
    else
      enable_staff_vision!
    end
  end

  # Check if this character instance can receive staff vision broadcasts
  # Must be:
  # - A staff character
  # - With staff_vision_enabled turned on
  # - Owner has can_see_all_rp permission
  # @return [Boolean]
  def can_receive_staff_broadcasts?
    character.staff_character? &&
      staff_vision_enabled? &&
      character.can_see_all_rp?
  end

  # Check if this is a staff character (delegate to character)
  def staff_character?
    character.staff_character?
  end

  # ========================================
  # Content Consent Room Timer Tracking
  # ========================================

  # Record when character entered current room (for consent timer)
  def record_room_entry!
    update(room_entered_at: Time.now, consent_display_triggered: false)
  end

  # Get seconds since entering the room
  def room_stable_duration
    return 0 unless room_entered_at

    (Time.now - room_entered_at).to_i
  end

  # Check if 10-minute timer has elapsed for consent display
  def consent_display_ready?
    room_stable_duration >= 600 # 10 minutes
  end

  # Mark that consent notification has been shown to this character
  def mark_consent_displayed!
    update(consent_display_triggered: true)
  end

  # Check if consent has already been displayed
  def consent_displayed?
    consent_display_triggered == true
  end

  # ========================================
  # Phone/Communication System (Era-Aware)
  # ========================================

  # Check if this character has access to a phone/communicator
  # Era-aware: checks for implants (always available) or physical devices
  # @return [Boolean]
  def has_phone?
    return false unless EraService.phones_available?

    # Near-future and sci-fi have always-available implants/communicators
    return true if EraService.always_connected?

    # Check for physical phone device in inventory
    if objects_dataset.where(is_phone: true).any?
      return true
    end

    # Gaslight era: landlines are room-specific
    if EraService.gaslight? && EraService.phones_room_locked?
      return current_room&.has_landline == true
    end

    false
  end
  alias phone? has_phone?

  # Get the phone/communicator device if character has one
  # @return [Item, nil]
  def phone_device
    objects_dataset.where(is_phone: true).first
  end

  # Check if character is at a location with a landline (for gaslight era)
  # @return [Boolean]
  def at_landline?
    current_room&.has_landline == true
  end

  # ========================================
  # TTS Narration System
  # ========================================

  # Check if TTS narration is enabled for this character instance
  # @return [Boolean]
  def tts_enabled?
    tts_enabled == true
  end

  # Toggle TTS narration on/off
  # @return [Boolean] new state
  def toggle_tts!
    update(tts_enabled: !tts_enabled?)
    tts_enabled?
  end

  # Enable TTS narration
  def enable_tts!
    update(tts_enabled: true)
  end

  # Disable TTS narration
  def disable_tts!
    update(tts_enabled: false)
  end

  # Configure which content types to narrate
  # @param speech [Boolean] narrate character speech (say, whisper, yell)
  # @param actions [Boolean] narrate emotes and actions
  # @param rooms [Boolean] narrate room descriptions
  # @param system [Boolean] narrate system messages
  def configure_tts!(speech: nil, actions: nil, rooms: nil, system: nil)
    updates = {}
    updates[:tts_narrate_speech] = speech unless speech.nil?
    updates[:tts_narrate_actions] = actions unless actions.nil?
    updates[:tts_narrate_rooms] = rooms unless rooms.nil?
    updates[:tts_narrate_system] = system unless system.nil?
    update(updates) unless updates.empty?
  end

  # Get current TTS settings hash
  # @return [Hash]
  def tts_settings
    {
      enabled: tts_enabled?,
      narrate_speech: tts_narrate_speech != false,
      narrate_actions: tts_narrate_actions != false,
      narrate_rooms: tts_narrate_rooms != false,
      narrate_system: tts_narrate_system != false
    }
  end

  # Check if a specific content type should be narrated
  # @param type [Symbol] :speech, :actions, :rooms, :system
  # @return [Boolean]
  def should_narrate?(type)
    return false unless tts_enabled?

    case type
    when :speech then tts_narrate_speech != false
    when :actions then tts_narrate_actions != false
    when :rooms then tts_narrate_rooms != false
    when :system then tts_narrate_system != false
    else false
    end
  end

  # ========================================
  # Accessibility Mode Helpers
  # ========================================

  # Check if accessibility mode is enabled for this character
  # Delegates to user-level setting
  # @return [Boolean]
  def accessibility_mode?
    character&.user&.accessibility_mode? == true
  end

  # Check if screen reader mode is enabled
  # @return [Boolean]
  def screen_reader_mode?
    character&.user&.screen_reader_mode? == true
  end

  # ========================================
  # TTS Queue Management
  # ========================================

  one_to_many :audio_queue_items

  # Check if TTS is paused
  # @return [Boolean]
  def tts_paused?
    tts_paused == true
  end

  # Pause TTS narration
  def pause_tts!
    update(tts_paused: true)
  end

  # Resume TTS narration
  def resume_tts!
    update(tts_paused: false)
  end

  # Get pending (unplayed) audio items
  # @return [Sequel::Dataset]
  def pending_audio_items
    audio_queue_items_dataset
      .where(played: false)
      .order(:sequence_number)
  end

  # Get current audio queue position
  # @return [Integer]
  def current_audio_position
    tts_queue_position || 0
  end

  # Advance audio queue position
  # @param new_position [Integer]
  def advance_audio_position!(new_position)
    update(tts_queue_position: new_position)
  end

  # Skip to the latest audio content
  def skip_to_latest!
    latest = audio_queue_items_dataset.max(:sequence_number) || 0
    update(tts_queue_position: latest, tts_paused: false)
  end

  # Clear entire audio queue
  def clear_audio_queue!
    audio_queue_items_dataset.delete
    update(tts_queue_position: 0)
  end

  # ========================================
  # Auto-GM Session System
  # ========================================

  # Check if this character instance is participating in an Auto-GM session
  # @return [Boolean]
  def in_auto_gm_session?
    !active_auto_gm_session.nil?
  end

  # Get the active Auto-GM session this character is participating in
  # @return [AutoGmSession, nil]
  def active_auto_gm_session
    AutoGmSession.for_participant(self).first
  end

  # Get all Auto-GM sessions this character has participated in
  # @param limit [Integer]
  # @return [Array<AutoGmSession>]
  def auto_gm_session_history(limit: 10)
    AutoGmSession
      .where(Sequel.pg_array_op(:participant_ids).contains([id]))
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # ========================================
  # Prisoner/Restraint System
  # ========================================

  # Check if character is helpless (can be restrained, searched, dragged)
  # @return [Boolean]
  def helpless?
    is_helpless == true
  end

  # Check if character is unconscious (knocked out)
  # @return [Boolean]
  def unconscious?
    status == 'unconscious'
  end

  # Check if hands are bound
  # @return [Boolean]
  def hands_bound?
    hands_bound == true
  end

  # Check if feet are bound
  # @return [Boolean]
  def feet_bound?
    feet_bound == true
  end

  # Check if character is gagged
  # @return [Boolean]
  def gagged?
    is_gagged == true
  end

  # Check if character is blindfolded
  # @return [Boolean]
  def blindfolded?
    is_blindfolded == true
  end

  # Check if any restraints are applied
  # @return [Boolean]
  def restrained?
    hands_bound? || feet_bound? || gagged? || blindfolded?
  end

  # Check if character is being dragged by someone
  # @return [Boolean]
  def being_dragged?
    !being_dragged_by_id.nil?
  end

  # Check if character is being carried by someone
  # @return [Boolean]
  def being_carried?
    !being_carried_by_id.nil?
  end

  # Check if character is being moved by someone (dragged or carried)
  # @return [Boolean]
  def being_moved?
    being_dragged? || being_carried?
  end

  # Get the character who is dragging or carrying this one
  # @return [CharacterInstance, nil]
  def captor
    being_dragged_by || being_carried_by
  end

  # Check if character is dragging someone
  # @return [Boolean]
  def dragging_someone?
    CharacterInstance.where(being_dragged_by_id: id).any?
  end

  # Check if character is carrying someone
  # @return [Boolean]
  def carrying_someone?
    CharacterInstance.where(being_carried_by_id: id).any?
  end

  # Get all prisoners this character is moving
  # @return [Array<CharacterInstance>]
  def prisoners
    CharacterInstance.where(
      Sequel.or(
        being_dragged_by_id: id,
        being_carried_by_id: id
      )
    ).all
  end

  # Check if character can be woken up (past 1 minute threshold)
  # @return [Boolean]
  def can_wake?
    return false unless unconscious?
    return false unless can_wake_at

    Time.now >= can_wake_at
  end

  # Check if character should auto-wake (past 10 minute threshold)
  # @return [Boolean]
  def should_auto_wake?
    return false unless unconscious?
    return false unless auto_wake_at

    Time.now >= auto_wake_at
  end

  # Get seconds until character can be manually woken
  # @return [Integer]
  def seconds_until_wakeable
    return 0 if can_wake?
    return 60 unless can_wake_at # Default 1 minute if not set

    [(can_wake_at - Time.now).to_i, 0].max
  end

  # Get seconds until character will auto-wake
  # @return [Integer]
  def seconds_until_auto_wake
    return 0 if should_auto_wake?
    return 600 unless auto_wake_at # Default 10 minutes if not set

    [(auto_wake_at - Time.now).to_i, 0].max
  end

  # Check if character can speak (not gagged)
  # @return [Boolean]
  def can_speak?
    !gagged?
  end

  # Check if character can see (not blindfolded)
  # Note: This is for prisoner blindfold, not the visibility/sightline system
  # @return [Boolean]
  def can_see_world?
    !blindfolded?
  end

  # Check if character can move independently (not bound feet or being moved)
  # @return [Boolean]
  def can_move_independently?
    return false if unconscious?
    return false if feet_bound?
    return false if being_moved?

    true
  end

  # Get description of current restraint status
  # @return [String, nil]
  def restraint_status_text
    parts = []
    parts << 'unconscious' if unconscious?
    parts << 'hands bound' if hands_bound?
    parts << 'feet bound' if feet_bound?
    parts << 'gagged' if gagged?
    parts << 'blindfolded' if blindfolded?
    parts << "being dragged by #{being_dragged_by.full_name}" if being_dragged?
    parts << "being carried by #{being_carried_by.full_name}" if being_carried?

    parts.empty? ? nil : parts.join(', ')
  end

  # ========================================
  # NPC Puppeteering System
  # ========================================

  # Association to the staff member who is puppeteering this NPC
  many_to_one :puppeteer, class: :CharacterInstance, key: :puppeted_by_instance_id

  # Dataset method for finding puppets
  dataset_module do
    # NPCs being puppeted by a specific character
    def puppeted_by(staff_instance_id)
      where(puppeted_by_instance_id: staff_instance_id)
    end
  end

  # Check if this NPC is being puppeted
  # @return [Boolean]
  def puppeted?
    puppet_mode != 'none' && !puppeted_by_instance_id.nil?
  end

  # Check if in full puppet mode (manual control, suggestions routed to staff)
  # @return [Boolean]
  def puppet_mode?
    puppet_mode == 'puppet'
  end

  # Check if in seed mode (instruction influences next LLM action)
  # @return [Boolean]
  def seed_mode?
    puppet_mode == 'seed'
  end

  # Get all NPCs this character instance is currently puppeting
  # @return [Array<CharacterInstance>]
  def puppets
    CharacterInstance.where(puppeted_by_instance_id: id).all
  end

  # Get count of NPCs being puppeted
  # @return [Integer]
  def puppet_count
    CharacterInstance.where(puppeted_by_instance_id: id).count
  end

  # Check if this character is puppeting any NPCs
  # @return [Boolean]
  def puppeting_any?
    puppet_count > 0
  end

  # Start puppeting an NPC (full control mode)
  # @param npc_instance [CharacterInstance] the NPC to puppet
  # @return [Hash] result with :success and :message
  def start_puppeting!(npc_instance)
    return { success: false, message: 'Cannot puppet yourself.' } if npc_instance.id == id
    return { success: false, message: 'That character is not an NPC.' } unless npc_instance.character&.npc?

    if npc_instance.puppeted? && npc_instance.puppeted_by_instance_id != id
      puppeteer_name = npc_instance.puppeteer&.full_name || 'someone'
      return { success: false, message: "#{npc_instance.full_name} is already being puppeted by #{puppeteer_name}." }
    end

    npc_instance.update(
      puppeted_by_instance_id: id,
      puppet_mode: 'puppet',
      puppet_started_at: Time.now,
      pending_puppet_suggestion: nil
    )

    { success: true, message: "You are now puppeting #{npc_instance.full_name}." }
  end

  # Stop puppeting an NPC
  # @param npc_instance [CharacterInstance] the NPC to release
  # @return [Hash] result with :success and :message
  def stop_puppeting!(npc_instance)
    unless npc_instance.puppeted_by_instance_id == id
      return { success: false, message: "You are not puppeting #{npc_instance.full_name}." }
    end

    npc_instance.update(
      puppeted_by_instance_id: nil,
      puppet_mode: 'none',
      puppet_started_at: nil,
      puppet_instruction: nil,
      pending_puppet_suggestion: nil
    )

    { success: true, message: "You have stopped puppeting #{npc_instance.full_name}." }
  end

  # Stop puppeting all NPCs
  # @return [Hash] result with :success, :message, and :count
  def stop_puppeting_all!
    puppets_list = puppets
    return { success: true, message: 'You are not puppeting any NPCs.', count: 0 } if puppets_list.empty?

    puppets_list.each do |npc|
      npc.update(
        puppeted_by_instance_id: nil,
        puppet_mode: 'none',
        puppet_started_at: nil,
        puppet_instruction: nil,
        pending_puppet_suggestion: nil
      )
    end

    { success: true, message: "Released #{puppets_list.length} puppet(s).", count: puppets_list.length }
  end

  # Seed an instruction into an NPC for their next LLM action
  # @param instruction [String] the instruction to seed
  # @return [Hash] result with :success and :message
  def seed_instruction!(instruction)
    return { success: false, message: 'This NPC is being fully puppeted.' } if puppet_mode?

    update(
      puppet_instruction: instruction,
      puppet_mode: 'seed'
    )

    { success: true, message: 'Instruction seeded for next action.' }
  end

  # Clear seeded instruction (called after LLM uses it)
  def clear_seed_instruction!
    update(
      puppet_instruction: nil,
      puppet_mode: 'none'
    )
  end

  # Set pending suggestion (called by animation handler when puppeted)
  # @param suggestion [String] the LLM-generated suggestion
  def set_puppet_suggestion!(suggestion)
    update(pending_puppet_suggestion: suggestion)
  end

  # Clear pending suggestion (called after staff executes or dismisses it)
  def clear_puppet_suggestion!
    update(pending_puppet_suggestion: nil)
  end

  # Get formatted puppet status for display
  # @return [Hash, nil] status info or nil if not puppeted
  def puppet_status
    return nil unless puppeted?

    {
      puppeteer_name: puppeteer&.full_name,
      mode: puppet_mode,
      started_at: puppet_started_at,
      has_instruction: !puppet_instruction.nil? && !puppet_instruction.empty?,
      has_suggestion: !pending_puppet_suggestion.nil? && !pending_puppet_suggestion.empty?,
      pending_suggestion: pending_puppet_suggestion
    }
  end

  # ========================================
  # Flashback Travel System
  # ========================================
  # Characters accumulate "flashback time" based on time since last RP activity.
  # This time can be used to reduce or eliminate world travel time.

  # Get available flashback time in seconds
  # Time since last RP activity, capped at 12 hours
  #
  # @return [Integer] seconds of available flashback time
  def flashback_time_available
    return 0 unless last_rp_activity_at

    elapsed = Time.now - last_rp_activity_at
    [elapsed.to_i, GameConfig::Journey::FLASHBACK_MAX_SECONDS].min
  end

  # Get co-travelers (only interactable characters during instanced state)
  #
  # @return [Array<CharacterInstance>]
  def flashback_co_travelers_instances
    return [] unless flashback_co_travelers&.any?

    CharacterInstance.where(id: flashback_co_travelers).all
  end

  # Check if character can interact with another during flashback instance
  #
  # @param other [CharacterInstance]
  # @return [Boolean]
  def can_interact_during_flashback?(other)
    return true unless flashback_instanced?

    # Can interact with self
    return true if other.id == id

    # Can interact with co-travelers
    flashback_co_travelers&.include?(other.id) || false
  end

  # Update last RP activity timestamp
  # Called when RP occurs in the character's room
  def touch_rp_activity!
    update(last_rp_activity_at: Time.now)
  end

  # Clear flashback state (called when leaving instance)
  def clear_flashback_state!
    update(
      flashback_instanced: false,
      flashback_travel_mode: nil,
      flashback_time_reserved: 0,
      flashback_origin_room_id: nil,
      flashback_co_travelers: Sequel.pg_jsonb_wrap([]),
      flashback_return_debt: 0
    )
  end

  # Enter flashback instanced state
  #
  # @param mode [String] 'return' or 'backloaded'
  # @param origin_room [Room] where the journey started
  # @param destination_location [Location] where traveling to
  # @param co_travelers [Array<Integer>] character instance IDs of co-travelers
  # @param reserved_time [Integer] seconds reserved for return (for 'return' mode)
  # @param return_debt [Integer] seconds of return debt (for 'backloaded' mode)
  def enter_flashback_instance!(mode:, origin_room:, destination_location:, co_travelers: [], reserved_time: 0, return_debt: 0)
    update(
      flashback_instanced: true,
      flashback_travel_mode: mode,
      flashback_origin_room_id: origin_room.id,
      flashback_co_travelers: Sequel.pg_jsonb_wrap(co_travelers),
      flashback_time_reserved: reserved_time,
      flashback_return_debt: return_debt
    )
  end

  # Get the origin room for flashback return
  #
  # @return [Room, nil]
  def flashback_origin_room
    return nil unless flashback_origin_room_id

    Room[flashback_origin_room_id]
  end

  # ========================================
  # Interaction Context Tracking
  # ========================================
  # Tracks recent interactions for implicit target resolution.
  # Used by the forgiving parser to allow commands like "reply" without specifying target.

  INTERACTION_CONTEXT_TIMEOUT = GameConfig::Timeouts::INTERACTION_CONTEXT_TIMEOUT

  # Set the last person who spoke to this character
  # @param character_instance [CharacterInstance, nil] the speaker
  def set_last_speaker(character_instance)
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_speaker_id: character_instance&.id,
      last_speaker_at: Time.now
    )
    refresh
  end

  # Get the last speaker if still valid (in room, not expired)
  # @return [CharacterInstance, nil]
  def last_speaker
    return nil unless last_speaker_id && last_speaker_at
    return nil if Time.now - last_speaker_at > INTERACTION_CONTEXT_TIMEOUT

    speaker = CharacterInstance[last_speaker_id]
    return nil unless speaker&.current_room_id == current_room_id

    speaker
  end

  # Set the last person this character spoke to
  # @param character_instance [CharacterInstance, nil] the target
  def set_last_spoken_to(character_instance)
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_spoken_to_id: character_instance&.id,
      last_spoken_to_at: Time.now
    )
    refresh
  end

  # Get the last person spoken to if still valid
  # @return [CharacterInstance, nil]
  def last_spoken_to
    return nil unless last_spoken_to_id && last_spoken_to_at
    return nil if Time.now - last_spoken_to_at > INTERACTION_CONTEXT_TIMEOUT

    target = CharacterInstance[last_spoken_to_id]
    return nil unless target&.current_room_id == current_room_id

    target
  end

  # Set the last combat target
  # @param character_instance [CharacterInstance, nil] the target
  def set_last_combat_target(character_instance)
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_combat_target_id: character_instance&.id,
      last_combat_target_at: Time.now
    )
    refresh
  end

  # Get the last combat target (doesn't expire, but must still exist)
  # @return [CharacterInstance, nil]
  def last_combat_target
    return nil unless last_combat_target_id

    CharacterInstance[last_combat_target_id]
  end

  # Set the last person who interacted (gave/showed something)
  # @param character_instance [CharacterInstance, nil] the interactor
  def set_last_interactor(character_instance)
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_interactor_id: character_instance&.id,
      last_interactor_at: Time.now
    )
    refresh
  end

  # Get the last interactor if still valid
  # @return [CharacterInstance, nil]
  def last_interactor
    return nil unless last_interactor_id && last_interactor_at
    return nil if Time.now - last_interactor_at > INTERACTION_CONTEXT_TIMEOUT

    interactor = CharacterInstance[last_interactor_id]
    return nil unless interactor&.current_room_id == current_room_id

    interactor
  end

  # ========================================
  # OOC/MSG Reply Tracking
  # ========================================
  # Tracks who last OOC'd or MSG'd this character, for the reply command.

  # Get the character who last OOC'd this character
  # @return [Character, nil]
  def last_ooc_sender
    return nil unless last_ooc_sender_character_id

    Character[last_ooc_sender_character_id]
  end

  # Get the character who last MSG'd this character
  # @return [Character, nil]
  def last_msg_sender
    return nil unless last_msg_sender_character_id

    Character[last_msg_sender_character_id]
  end

  # Get the most recent OOC/MSG sender for the reply command
  # @return [Hash, nil] { type: :ooc/:msg, character: Character } or nil
  def last_reply_target
    ooc_char = last_ooc_sender
    msg_char = last_msg_sender

    return nil if ooc_char.nil? && msg_char.nil?
    return { type: :ooc, character: ooc_char } if ooc_char && msg_char.nil?
    return { type: :msg, character: msg_char } if msg_char && ooc_char.nil?

    # Both exist - pick whichever is more recent
    if last_ooc_sender_at && last_msg_sender_at
      if last_ooc_sender_at >= last_msg_sender_at
        { type: :ooc, character: ooc_char }
      else
        { type: :msg, character: msg_char }
      end
    elsif last_ooc_sender_at
      { type: :ooc, character: ooc_char }
    else
      { type: :msg, character: msg_char }
    end
  end

  # Clear all interaction context (called on room change, disconnect)
  # Note: last_combat_target preserved intentionally
  def clear_interaction_context!
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_speaker_id: nil,
      last_speaker_at: nil,
      last_spoken_to_id: nil,
      last_spoken_to_at: nil,
      last_interactor_id: nil,
      last_interactor_at: nil
    )
    refresh
  end

  # Clear combat context (called when combat ends)
  def clear_combat_context!
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      last_combat_target_id: nil,
      last_combat_target_at: nil
    )
    refresh
  end

  # Initialize stats for a new instance from the best available source:
  # 1. Another instance of the same character (copy current stats)
  # 2. Character's chargen stat_allocations (from character creation form)
  # 3. Active stat blocks at minimum values (fallback)
  def initialize_stats_from_character
    # Try copying from an existing instance first
    source = CharacterInstance.where(character_id: character_id)
                              .exclude(id: id)
                              .first
    if source && !source.character_stats.empty?
      source.character_stats.each do |cs|
        CharacterStat.create(
          character_instance_id: id,
          stat_id: cs.stat_id,
          base_value: cs.base_value
        )
      end
      return
    end

    # Try chargen allocations stored on the Character
    allocs = character&.stat_allocations
    if allocs.is_a?(Hash) && allocs.any?
      StatAllocationService.create_stats_for_character(self, allocs)
      return
    end

    # Fallback: initialize at minimum values
    StatAllocationService.initialize_default_stats(self)
  end

  # --- Combat Preferences ---

  # Read a single combat preference by key.
  # @param key [Symbol, String] e.g. :melee_weapon_id, :ignore_hazard_avoidance
  # @return [Object, nil]
  def combat_preference(key)
    prefs = combat_preferences
    return nil if prefs.nil? || prefs.empty?

    prefs[key.to_s]
  end

  # Write a single combat preference, preserving others.
  # Uses Sequel JSONB dirty-tracking-safe pattern.
  # @param key [Symbol, String]
  # @param value [Object, nil]
  def set_combat_preference(key, value)
    current = JSON.parse((combat_preferences || {}).to_json)
    if value.nil?
      current.delete(key.to_s)
    else
      current[key.to_s] = value
    end
    update(combat_preferences: Sequel.pg_jsonb_wrap(current))
  end
end
