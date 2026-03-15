# frozen_string_literal: true

require 'timeout'

# Orchestrates combat sessions - starting fights, managing participants,
# processing choices, and triggering round resolution.
class FightService
  class RoundResolutionError < StandardError; end

  attr_reader :fight

  def initialize(fight = nil)
    @fight = fight
  end

  # Start a new fight or join an existing one in a room
  # @param room [Room] the room where combat takes place
  # @param room [Room] the room where the fight takes place
  # @param initiator [CharacterInstance] the character starting the fight
  # @param target [CharacterInstance] the character being attacked
  # @param mode [String] fight mode: 'normal' (default) or 'spar'
  # @return [FightService] the service instance managing the fight
  def self.start_fight(room:, initiator:, target:, mode: 'normal')
    mode = normalize_mode(mode)

    # Check for existing ongoing fight in room
    existing = find_ongoing_fight_in_room(room, mode: mode)

    if existing
      # Join existing fight - pass target info for side assignment
      service = new(existing)
      service.add_participant(initiator, target_instance: target) unless service.participant_for(initiator)
      service.add_participant(target, target_instance: initiator) unless service.participant_for(target)
      return service
    end

    # Create new fight with specified mode
    fight = Fight.create(room_id: room.id, mode: mode)

    # Set battle_map_generating flag BEFORE adding participants so the
    # spar/fight command sees the flag and returns "Generating..." status.
    # The actual Thread is spawned AFTER participants are added to avoid
    # a race condition where generation completes before participants exist.
    needs_battle_map = room_needs_battle_map?(room)
    fight.start_battle_map_generation! if needs_battle_map

    # Snapshot all character distances at fight start for entry delay system
    FightEntryDelayService.snapshot_distances(fight)

    service = new(fight)
    # Initiator goes to side 1, target to side 2 (attacking initiator)
    service.add_participant(initiator)
    service.add_participant(target, target_instance: initiator)

    # Reset the input deadline now that participants are added
    # (before_create runs before participants exist, so the timeout is wrong)
    fight.reset_input_deadline!
    fight.save_changes

    # Now spawn async generation thread - participants exist so
    # push_quickmenus_to_participants will find them when generation completes
    kick_off_async_generation(room, fight) if needs_battle_map

    service
  end

  # Find an ongoing fight in a room, optionally filtered by mode.
  # @param room [Room]
  # @param mode [String, nil] 'normal', 'spar', or nil for any
  # @return [Fight, nil]
  def self.find_ongoing_fight_in_room(room, mode: nil)
    scope = Fight.where(room_id: room.id)
                .where(status: %w[input resolving narrative])
    return scope.first if mode.nil?

    mode = normalize_mode(mode)
    if mode == 'normal'
      scope.where(mode: [nil, 'normal']).first
    else
      scope.where(mode: mode).first
    end
  end

  # Check if a room has an ongoing fight with a different mode.
  # @param room [Room]
  # @param mode [String] desired mode
  # @return [Fight, nil] conflicting fight if present
  def self.find_conflicting_mode_fight_in_room(room, mode:)
    mode = normalize_mode(mode)
    scope = Fight.where(room_id: room.id)
                .where(status: %w[input resolving narrative])

    if mode == 'normal'
      scope.exclude(mode: [nil, 'normal']).first
    else
      scope.exclude(mode: mode).first
    end
  end

  # Create a fight for an activity (simpler than start_fight which requires initiator/target)
  # @param room [Room] the room where combat takes place
  # @param activity_instance_id [Integer] the activity instance ID
  # @return [Fight] the created fight
  def self.create_fight(room:, activity_instance_id: nil)
    Fight.create(
      room_id: room.id,
      activity_instance_id: activity_instance_id,
      has_monster: true
    )
  end

  # Immediately resolve the round when all inputs are complete
  # Called from CombatQuickmenuHandler#check_round_resolution
  # Replicates the scheduler's resolution flow but triggers without waiting for timeout
  # @param fight [Fight] the fight to resolve
  def self.try_advance_round(fight)
    fight.reload
    return unless fight.all_inputs_complete?
    return if fight.round_locked?

    fight_service = new(fight)

    # Apply defaults and resolve
    result = fight_service.resolve_round!
    roll_display = result[:roll_display]
    narrative = fight_service.generate_narrative

    # Broadcast roll display first (shows dice rolls with animations)
    if roll_display&.any?
      BroadcastService.to_room(
        fight.room_id,
        { type: 'roll_display', rolls: roll_display },
        type: :combat_rolls,
        fight_id: fight.id,
        round: fight.round_number
      )
    end

    # Broadcast narrative personalized per viewer
    room_chars = CharacterInstance.where(
      current_room_id: fight.room_id, online: true
    ).eager(:character).all

    room_chars.each do |viewer|
      personalized = MessagePersonalizationService.personalize(
        message: narrative,
        viewer: viewer,
        room_characters: room_chars
      )
      BroadcastService.to_character(
        viewer,
        personalized,
        type: :combat,
        fight_id: fight.id,
        round: fight.round_number
      )
    end

    # Check for fight completion
    fight.reload
    if fight.status == 'complete'
      # Fight already ended during resolution
    elsif fight_service.should_end?
      fight_service.end_fight!
      logger = fight_service.instance_variable_get(:@last_resolution_service)&.logger
      if logger
        reason = fight.spar_mode? ? 'spar_touch_limit' : 'side_eliminated_or_last_standing'
        logger.log_fight_end(reason)
        logger.flush!
      end
    else
      # Start next round (resets input, applies NPC AI decisions)
      CombatQuickmenuHandler.start_next_round_for(fight_service)
    end
  rescue StandardError => e
    warn "[FightService] try_advance_round failed for fight #{fight.id}: #{e.message}"
    begin
      fight.reload
      if fight.status == 'resolving' || fight.round_locked?
        fight.update(status: 'input', round_locked: false, last_action_at: Time.now)
      end
    rescue StandardError => recovery_error
      warn "[FightService] try_advance_round recovery failed for fight #{fight.id}: #{recovery_error.message}"
    end
  end

  # Resolve all fights with timed-out input and unstick fights in terminal states.
  # Called by the scheduler every tick — all fight orchestration logic lives here,
  # not inline in the scheduler.
  # @return [Hash] { resolved: Integer, unstuck: Integer, errors: Array }
  def self.resolve_timed_out_rounds!
    resolved = 0
    unstuck = 0
    errors = []

    # Phase 1: fights in 'input' status that have timed out
    Fight.where(status: 'input').each do |fight|
      if fight.battle_map_generating
        fight.reset_input_deadline!
        fight.save_changes
        next
      end

      next unless fight.input_timed_out?

      begin
        fight_service = new(fight)
        fight_service.send(:apply_defaults!)
        result = fight_service.resolve_round!
        roll_display = result[:roll_display]
        narrative = fight_service.generate_narrative

        if roll_display&.any?
          BroadcastService.to_room(
            fight.room_id,
            { type: 'roll_display', rolls: roll_display },
            type: :combat_rolls,
            fight_id: fight.id,
            round: fight.round_number
          )
        end

        room_chars = CharacterInstance.where(
          current_room_id: fight.room_id, online: true
        ).eager(:character).all

        room_chars.each do |viewer|
          personalized = MessagePersonalizationService.personalize(
            message: narrative,
            viewer: viewer,
            room_characters: room_chars
          )
          BroadcastService.to_character(
            viewer,
            personalized,
            type: :combat,
            fight_id: fight.id,
            round: fight.round_number
          )
        end

        fight.reload
        if fight.status == 'complete'
          resolved += 1
        elsif fight_service.should_end?
          fight_service.end_fight!
          resolved += 1
        else
          fight_service.next_round!
          resolved += 1
        end
      rescue StandardError => e
        errors << { fight_id: fight.id, error: e.message, phase: 'input_timeout' }
      end
    end

    # Phase 2: fights stuck in 'narrative' or 'resolving' (partially processed)
    stuck_cutoff = Time.now - 60
    Fight.where(status: %w[narrative resolving]).each do |fight|
      next if fight.last_action_at && fight.last_action_at > stuck_cutoff

      begin
        fight_service = new(fight)
        if fight_service.should_end?
          fight_service.end_fight!
        else
          fight_service.next_round!
        end
        unstuck += 1
      rescue StandardError => e
        errors << { fight_id: fight.id, error: e.message, phase: 'stuck_recovery' }
      end
    end

    # Phase 3: fights with invalid status
    Fight.where(Sequel.~(status: Fight::STATUSES)).each do |fight|
      begin
        fight.update(status: 'complete', last_action_at: fight.last_action_at || Time.now)
        unstuck += 1
      rescue StandardError => e
        errors << { fight_id: fight.id, error: e.message, phase: 'invalid_status_fix' }
      end
    end

    warn "[Combat] Auto-resolved #{resolved} timed-out round(s)" if resolved > 0
    warn "[Combat] Recovered #{unstuck} stuck fight(s)" if unstuck > 0
    errors.each do |err|
      warn "[Combat] Error in #{err[:phase]} for fight ##{err[:fight_id]}: #{err[:error]}"
    end

    { resolved: resolved, unstuck: unstuck, errors: errors }
  rescue StandardError => e
    warn "[FightService] resolve_timed_out_rounds! failed: #{e.message}"
    { resolved: 0, unstuck: 0, errors: [{ error: e.message, phase: 'top_level' }] }
  end

  # Add a character instance as a combatant to an existing fight.
  # Convenience class method — delegates to the instance method add_participant.
  # @param fight [Fight] the fight to join
  # @param character_instance [CharacterInstance] the character to add
  # @param side [Integer] which side (default 1 for players)
  def self.add_combatant(fight, character_instance, side: 1)
    new(fight).add_participant(character_instance, side: side)
  end

  # Spawn an NPC combatant from an archetype
  # @param fight [Fight] the fight to join
  # @param npc_archetype [NpcArchetype] the NPC template
  # @param level [Integer] the NPC level (affects stats)
  # @param side [Integer] which side (default 2 for enemies)
  # @param stat_modifier [Float] difficulty modifier from battle balancing (-0.5..0.5)
  def self.spawn_npc_combatant(fight, npc_archetype, level: 1, side: 2, stat_modifier: 0.0)
    base_stats = npc_archetype.respond_to?(:combat_stats) ? npc_archetype.combat_stats : {}
    adjusted_stats = if stat_modifier.to_f.zero?
                       base_stats
                     else
                       PowerCalculatorService.apply_difficulty_modifier(npc_archetype, stat_modifier.to_f)
                     end

    adjusted_max_hp = adjusted_stats[:max_hp] || 10
    npc_instance = create_npc_combat_instance(
      fight: fight,
      npc_archetype: npc_archetype,
      level: level,
      max_hp: adjusted_max_hp
    )

    attrs = {
      fight_id: fight.id,
      is_npc: true,
      npc_name: npc_archetype.name,
      npc_damage_bonus: adjusted_stats[:damage_bonus] || 0,
      npc_defense_bonus: adjusted_stats[:defense_bonus] || 0,
      npc_speed_modifier: adjusted_stats[:speed_modifier] || 0,
      npc_damage_dice_count: adjusted_stats[:damage_dice_count] || 2,
      npc_damage_dice_sides: adjusted_stats[:damage_dice_sides] || 8,
      side: side
    }
    if npc_instance
      attrs[:character_instance_id] = npc_instance.id
    else
      attrs[:max_hp] = adjusted_max_hp
      attrs[:current_hp] = adjusted_max_hp
    end

    # Assign a hex position so NPCs don't all stack at (0,0)
    service = new(fight)
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    # Place NPCs on the far side of the arena (side 2 = right/bottom)
    raw_x = side == 1 ? 1 : [arena_w - 2, 0].max
    raw_y = side == 1 ? 2 : [((arena_h - 1) * 2), 0].max
    # Snap to valid hex coordinates
    desired_x, desired_y = HexGrid.to_hex_coords(raw_x, raw_y)
    hex_x, hex_y = service.find_unoccupied_hex(desired_x, desired_y)
    attrs[:hex_x] = hex_x
    attrs[:hex_y] = hex_y

    participant = FightParticipant.create(attrs)

    # NPCs decide immediately
    CombatAIService.new(participant).apply_decisions!

    participant
  end

  # Check if room needs battle map generation
  # @param room [Room] the room to check
  # @return [Boolean]
  def self.room_needs_battle_map?(room)
    return false unless room.min_x && room.max_x && room.min_y && room.max_y
    return false if room.battle_map_ready?

    # Check if another fight is already generating for this room
    # Prevent duplicate generation for active/recent jobs.
    # If a stale flag lingers forever, watchdog/startup cleanup will clear it.
    stale_cutoff = Time.now - 600
    existing_generation = Fight.where(room_id: room.id, battle_map_generating: true)
                               .where { updated_at > stale_cutoff }
                               .first
    return false if existing_generation

    true
  end

  # Kick off async battle map generation via Sidekiq.
  # Using a job process instead of a Thread keeps long-running external API calls
  # (Gemini image gen, SAM, Replicate) out of Puma where C-level IO blocks
  # resist Ruby Timeout interruption.
  # @param room [Room] the room to generate for
  # @param fight [Fight] the fight instance
  def self.kick_off_async_generation(room, fight)
    BattleMapGenerationJob.perform_async(room.id, fight.id)
  rescue StandardError => e
    warn "[FightService] Failed to enqueue battle map job: #{e.message}"
    fight.complete_battle_map_generation!
  end

  # Push combat quickmenus to all participants after battle map generation completes
  # @param fight [Fight] the fight instance
  def self.push_quickmenus_to_participants(fight)
    return unless fight&.ongoing?

    fight.refresh
    participants = fight.fight_participants
    participants.each do |participant|
      char_instance = participant.character_instance
      next unless char_instance&.online
      next if char_instance.character&.npc?  # NPCs auto-decide, don't need quickmenus

      begin
        menu_data = CombatQuickmenuHandler.show_menu(participant, char_instance)
        next unless menu_data

        # Store as pending interaction so player can respond
        interaction_id = SecureRandom.uuid
        stored = {
          interaction_id: interaction_id,
          type: 'quickmenu',
          prompt: menu_data[:prompt],
          options: menu_data[:options],
          context: menu_data[:context] || {},
          created_at: Time.now.iso8601
        }
        OutputHelper.store_agent_interaction(char_instance, interaction_id, stored)

        # Push quickmenu to client via WebSocket
        BroadcastService.to_character(
          char_instance,
          { content: "Battle map ready! Choose your combat action." },
          type: :quickmenu,
          data: {
            interaction_id: interaction_id,
            prompt: menu_data[:prompt],
            options: menu_data[:options]
          }
        )
      rescue StandardError => e
        warn "[FightService] Failed to push quickmenu to participant #{participant.id}: #{e.message}"
      end
    end
  rescue StandardError => e
    warn "[FightService] Failed to push quickmenus: #{e.message}"
  end

  # Revalidate all participant positions after battle map generation completes.
  # Participants placed before the map existed may be on hexes that are now walls/pits.
  # Moves any participant on a non-traversable hex to the nearest valid hex.
  # @param fight [Fight] the fight to revalidate
  def self.revalidate_participant_positions(fight)
    return unless fight&.ongoing?

    service = new(fight)
    room = fight.room
    return unless room

    fight.active_participants.each do |participant|
      next if participant.is_knocked_out

      next if RoomHex.playable_at?(room, participant.hex_x, participant.hex_y)

      new_x, new_y = service.find_unoccupied_hex(participant.hex_x, participant.hex_y)
      next if new_x == participant.hex_x && new_y == participant.hex_y

      warn "[FightService] Repositioned #{participant.character_name} from " \
           "(#{participant.hex_x},#{participant.hex_y}) to (#{new_x},#{new_y}) — was on non-traversable hex"
      participant.update(hex_x: new_x, hex_y: new_y)
      participant.sync_position_to_character!
    end
  end

  # Find an active fight for a character instance
  def self.find_active_fight(character_instance)
    FightParticipant.where(character_instance_id: character_instance.id)
                    .eager(:fight)
                    .all
                    .map(&:fight)
                    .find(&:ongoing?)
  end

  def self.normalize_mode(mode)
    normalized = mode.to_s.strip.downcase
    normalized.empty? ? 'normal' : normalized
  end

  # Initialize HP fields on CharacterInstance when missing.
  def self.ensure_character_health_defaults!(character_instance, max_hp: nil, current_hp: nil)
    return unless character_instance
    return unless character_instance.respond_to?(:update)

    ci_max = character_instance.respond_to?(:max_health) ? character_instance.max_health : nil
    ci_health = character_instance.respond_to?(:health) ? character_instance.health : nil

    target_max = (max_hp || ci_max || GameConfig::Mechanics::DEFAULT_HP[:max]).to_i
    target_max = 1 if target_max <= 0

    target_current = if current_hp.nil?
                       ci_health || target_max
                     else
                       current_hp
                     end
    target_current = [[target_current.to_i, 0].max, target_max].min

    attrs = {}
    attrs[:max_health] = target_max if character_instance.respond_to?(:max_health) && (!max_hp.nil? || ci_max.nil?)
    attrs[:health] = target_current if character_instance.respond_to?(:health) && (!current_hp.nil? || ci_health.nil?)
    character_instance.update(attrs) if attrs.any?
  rescue StandardError => e
    warn "[FightService] Failed to initialize character HP: #{e.message}"
  end

  # Create a dedicated NPC CharacterInstance for combat so HP lives on
  # character_instance.health/max_health.
  def self.create_npc_combat_instance(fight:, npc_archetype:, level:, max_hp:)
    return nil unless fight && npc_archetype

    reality = Reality.first(reality_type: 'primary') || Reality.first
    return nil unless reality

    npc_name = npc_archetype.generate_spawn_name
    npc_character = npc_archetype.create_unique_npc(npc_name)
    return nil unless npc_character

    CharacterInstance.create(
      character_id: npc_character.id,
      reality_id: reality.id,
      current_room_id: fight.room_id,
      level: [level.to_i, 1].max,
      health: max_hp.to_i,
      max_health: max_hp.to_i,
      mana: 50,
      max_mana: 50,
      online: false,
      status: 'alive'
    )
  rescue StandardError => e
    warn "[FightService] Failed to create NPC combat instance: #{e.message}"
    nil
  end

  # Add a participant to the fight
  # @param character_instance [CharacterInstance] the character joining
  # @param target_instance [CharacterInstance, nil] who they're attacking (for auto side assignment)
  # @param side [Integer, nil] explicit side override; nil = auto-determine from target_instance
  # @return [FightParticipant, nil] the created participant, or nil if already fled/surrendered
  def add_participant(character_instance, target_instance: nil, side: nil)
    return participant_for(character_instance) if participant_for(character_instance)

    return nil if character_instance.has_fled_from_fight?(fight)
    return nil if character_instance.has_surrendered_from_fight?(fight)

    melee, ranged = find_best_weapons(character_instance)
    melee, ranged = apply_weapon_preferences(character_instance, melee, ranged)
    starting_hex_x, starting_hex_y = calculate_starting_hex(character_instance)
    starting_hex_x, starting_hex_y = find_unoccupied_hex(starting_hex_x, starting_hex_y)

    side ||= determine_side_for_new_participant(target_instance)

    self.class.ensure_character_health_defaults!(character_instance)

    # Heal characters at 0 HP before joining — they shouldn't enter a fight already knocked out
    character_instance.refresh
    if character_instance.health && character_instance.health <= 0
      character_instance.update(health: character_instance.max_health || GameConfig::Mechanics::DEFAULT_HP[:max])
    end

    # Load hazard avoidance preference
    hazard_pref = character_instance.combat_preference(:ignore_hazard_avoidance)

    participant = FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: character_instance.id,
      melee_weapon_id: melee&.id,
      ranged_weapon_id: ranged&.id,
      hex_x: starting_hex_x,
      hex_y: starting_hex_y,
      side: side,
      ignore_hazard_avoidance: hazard_pref || false
    )

    # Stop observing when entering combat
    character_instance.stop_observing! if character_instance.observing?

    # NPCs decide immediately - they don't wait for player input
    if character_instance.character.npc?
      CombatAIService.new(participant).apply_decisions!
    end

    participant
  end

  # Determine side for a new participant joining the fight
  # @param target_instance [CharacterInstance, nil] who they're attacking
  # @return [Integer] the side number (1, 2, 3...)
  def determine_side_for_new_participant(target_instance)
    existing_participants = fight.fight_participants_dataset.all

    # First participant - side 1
    return 1 if existing_participants.empty?

    # If we know who they're targeting, join opposite side
    if target_instance
      target_participant = participant_for(target_instance)
      if target_participant
        # Join a different side than target
        target_side = target_participant.side
        side_counts = existing_participants.group_by(&:side).transform_values(&:count)
        opposing_sides = side_counts.keys.reject { |side| side == target_side }

        # Prefer an existing opposing side with fewer fighters (tie-break lower side number)
        unless opposing_sides.empty?
          min_count = opposing_sides.map { |side| side_counts[side] }.min
          return opposing_sides.sort.find { |side| side_counts[side] == min_count }
        end

        # No opposing side exists yet (all fighters on target's side), create one.
        return (side_counts.keys.max || 1) + 1
      end
    end

    # Second participant without explicit target - side 2 (opposing)
    return 2 if existing_participants.count == 1

    # Default: join the side with fewer fighters (auto-balance)
    side_counts = existing_participants.group_by(&:side).transform_values(&:count)
    # Find the side with minimum participants, prefer lower side numbers
    min_count = side_counts.values.min
    side_counts.keys.sort.find { |s| side_counts[s] == min_count } || 1
  end

  # Change a participant's side
  # @param participant [FightParticipant] the participant changing sides
  # @param new_side [Integer] the side to join (or nil to create new side)
  # @return [Integer] the new side number
  def change_side!(participant, new_side = nil)
    if new_side.nil?
      # Create a new side - find the highest current side and add 1
      max_side = fight.fight_participants_dataset.max(:side) || 1
      new_side = max_side + 1
    end

    participant.update(side: new_side)
    new_side
  end

  # Get the participant record for a character instance
  def participant_for(character_instance)
    fight.fight_participants_dataset
         .where(character_instance_id: character_instance.id)
         .first
  end

  # Process a quickmenu choice from a participant
  # @param participant [FightParticipant] the participant making the choice
  # @param stage [String] the current input stage
  # @param choice [String] the choice made
  def process_choice(participant, stage, choice)
    case stage
    when 'target'
      process_target_choice(participant, choice)
    when 'main'
      process_main_action_choice(participant, choice)
    when 'ability'
      process_ability_choice(participant, choice)
    when 'tactical_ability'
      process_tactical_ability_choice(participant, choice)
    when 'tactical'
      process_tactical_choice(participant, choice)
    when 'willpower'
      process_willpower_choice(participant, choice)
    when 'movement'
      process_movement_choice(participant, choice)
    when 'weapon_melee'
      process_weapon_choice(participant, choice, :melee)
    when 'weapon_ranged'
      process_weapon_choice(participant, choice, :ranged)
    end
  end

  # Apply default choices for participants who haven't completed input
  # Uses CombatAIService for intelligent defaults (NPCs and idle PCs)
  def apply_defaults!
    fight.participants_needing_input.each do |p|
      decisions = CombatAIService.new(p).apply_decisions!
      @combat_round_logger&.log_ai_decision(p, decisions) if decisions
    end
  end

  # Check if the fight is ready to resolve (all inputs complete or timed out)
  # Blocks resolution while battle map is still generating
  def ready_to_resolve?
    return false if fight.battle_map_generating

    fight.all_inputs_complete? || fight.input_timed_out?
  end

  # Trigger round resolution
  # @return [Hash] containing :events and :roll_display
  def resolve_round!
    # Create logger early so AI decisions can be logged
    @combat_round_logger = CombatRoundLogger.new(fight)

    # Always apply defaults for any participant who hasn't completed input
    # This ensures NPCs and AFK players get sensible choices applied
    apply_defaults!
    fight.advance_to_resolution!

    @last_resolution_service = CombatResolutionService.new(fight, logger: @combat_round_logger)
    result = @last_resolution_service.resolve!

    # Handle old array format from resolution (legacy compatibility)
    if result.is_a?(Array)
      result = { events: result, roll_display: nil, damage_summary: nil, errors: [] }
    end

    events = result[:events] || []
    roll_display = result[:roll_display]
    damage_summary = result[:damage_summary]
    errors = result[:errors] || []

    fight.update(round_events: events.to_json)

    if errors.any?
      error_lines = errors.map { |err| "#{err[:step]}: #{err[:error_class]} - #{err[:message]}" }.join(' | ')
      warn "[FightService] Round resolution had errors for fight #{fight.id}: #{error_lines}"
      # Don't raise - safe_execute intentionally allows partial round completion.
      # Raising here would leave the fight stuck in 'resolving' status.
    end

    # Don't overwrite status if resolution already ended the fight (e.g., mutual pass)
    fight.advance_to_narrative! unless fight.status == 'complete'

    # Re-render lighting with updated positions (gated behind feature flag)
    if fight.room&.has_battle_map && GameSetting.boolean('dynamic_lighting_enabled')
      DynamicLightingService.render_for_fight(fight)
    end

    { events: events, roll_display: roll_display, damage_summary: damage_summary, errors: errors }
  end

  # Generate narrative for the current round
  # @return [String] the narrative text
  def generate_narrative
    narrative = CombatNarrativeService.new(fight).generate
    @last_resolution_service&.log_narrative_and_flush(narrative)
    narrative
  end

  # Check if fight should end (one or zero active participants, or spar touch limit reached)
  def should_end?
    fight.should_end?
  end

  # End the fight
  def end_fight!
    fight.complete!
  end

  # Add a monster to the fight
  # @param monster_template [MonsterTemplate] the template to spawn from
  # @param hex_x [Integer] center hex x position
  # @param hex_y [Integer] center hex y position
  # @return [LargeMonsterInstance] the spawned monster
  def add_monster(monster_template, hex_x: nil, hex_y: nil)
    # Default to center of arena if no position specified
    hex_x ||= (fight.arena_width / 2).round
    hex_y ||= (fight.arena_height / 2).round

    # Spawn the monster using template method
    monster = monster_template.spawn_in_fight(fight, hex_x, hex_y)

    # Mark fight as having monsters
    fight.update(has_monster: true)

    # Hex occupation is calculated dynamically from monster position
    # No need to update - occupied_hexes is derived from center position and template dimensions

    monster
  end

  # Prepare for next round
  def next_round!
    # Expire status effects that have reached their duration
    StatusEffectService.expire_effects(fight)

    # Decay penalties, cooldowns, and reset willpower for all participants
    fight.fight_participants.each do |p|
      # New JSONB-based penalty decay
      p.decay_all_penalties!

      # New JSONB-based ability cooldown decay
      p.decay_ability_cooldowns!

      # Reset willpower allocations
      p.reset_willpower_allocations!

      # Reset menu state for new hub-style menu
      p.reset_menu_state!
    end

    fight.complete_round!
  end

  # Find an unoccupied hex, starting from the desired position
  # Uses a spiral search pattern to find the nearest available hex
  # Only returns hexes within arena bounds.
  # @param desired_x [Integer] preferred hex x
  # @param desired_y [Integer] preferred hex y
  # @return [Array<Integer, Integer>] unoccupied hex_x, hex_y
  def find_unoccupied_hex(desired_x, desired_y)
    taken = occupied_hexes
    max_x, max_y = arena_hex_bounds
    room = fight.room

    # If desired hex is free, in bounds, and traversable, use it
    if !taken.include?([desired_x, desired_y]) &&
       in_arena?(desired_x, desired_y, max_x, max_y) &&
       RoomHex.playable_at?(room, desired_x, desired_y)
      return [desired_x, desired_y]
    end

    # Spiral outward to find nearest unoccupied traversable hex within arena bounds
    (1..20).each do |distance|
      candidates = hexes_at_distance(desired_x, desired_y, distance)
      candidates.select! { |hx, hy| in_arena?(hx, hy, max_x, max_y) && RoomHex.playable_at?(room, hx, hy) }
      candidates.shuffle.each do |hx, hy|
        return [hx, hy] unless taken.include?([hx, hy])
      end
    end

    # Fallback: clamp to center of arena (shouldn't happen)
    clamp_to_arena(desired_x, desired_y)
  end

  private

  # Get all hexes currently occupied by fight participants and monsters
  # @return [Set<Array<Integer, Integer>>] set of [hex_x, hex_y] pairs
  def occupied_hexes
    hexes = Set.new

    # Use _dataset to get fresh data from database (avoid cached associations)
    fight.fight_participants_dataset.each do |p|
      hexes.add([p.hex_x, p.hex_y]) if p.hex_x && p.hex_y
    end

    # Add hexes occupied by large monsters (they can occupy multiple hexes)
    fight.large_monster_instances_dataset.where(status: 'active').each do |monster|
      monster.occupied_hexes.each { |h| hexes.add(h) }
    end

    hexes
  end

  # Find nearest traversable hex within arena bounds via spiral search
  # @param hex_x [Integer] starting hex x
  # @param hex_y [Integer] starting hex y
  # @param room [Room] the room to check traversability in
  # @return [Array<Integer, Integer>, nil] traversable hex coords, or nil if none found
  def find_nearest_traversable(hex_x, hex_y, room)
    max_x, max_y = arena_hex_bounds
    (1..20).each do |distance|
      candidates = hexes_at_distance(hex_x, hex_y, distance)
      candidates.select! { |hx, hy| in_arena?(hx, hy, max_x, max_y) && RoomHex.playable_at?(room, hx, hy) }
      return candidates.sample if candidates.any?
    end
    nil
  end

  # Get all valid hex coordinates at exactly the given distance from a center hex
  # @param center_x [Integer] center hex x
  # @param center_y [Integer] center hex y
  # @param distance [Integer] exact distance to find hexes at
  # @return [Array<Array<Integer, Integer>>] array of [hex_x, hex_y] pairs
  def hexes_at_distance(center_x, center_y, distance)
    return [[center_x, center_y]] if distance == 0

    result = []

    # Search in a bounding box and filter by exact distance
    range = distance * 2 + 2
    (-range..range).each do |dx|
      (-range..range).each do |dy|
        candidate_x = center_x + dx
        candidate_y = center_y + dy

        # Convert to valid hex coords
        hx, hy = HexGrid.to_hex_coords(candidate_x, candidate_y)

        # Check if this hex is exactly at the target distance
        if HexGrid.hex_distance(center_x, center_y, hx, hy) == distance
          result << [hx, hy] unless result.include?([hx, hy])
        end
      end
    end

    result
  end

  # Calculate starting hex position from character's room position with scatter
  # Maps feet position into arena coordinates (scaling if room > arena cap),
  # then adds 0-1 hex random scatter so participants don't stack exactly.
  # @param character_instance [CharacterInstance]
  # @return [Array<Integer, Integer>] hex_x, hex_y in arena coordinates
  def calculate_starting_hex(character_instance)
    room = fight.room
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    hex_max_x = [arena_w - 1, 0].max
    hex_max_y = [(arena_h - 1) * 4 + 2, 0].max

    room_min_x = room&.min_x || 0.0
    room_min_y = room&.min_y || 0.0
    room_max_x = room&.max_x || (room_min_x + arena_w * HexGrid::HEX_SIZE_FEET)
    room_max_y = room&.max_y || (room_min_y + arena_h * HexGrid::HEX_SIZE_FEET)
    room_width = [room_max_x - room_min_x, 1.0].max
    room_height = [room_max_y - room_min_y, 1.0].max

    char_x = character_instance.x || (room_min_x + room_width / 2.0)
    char_y = character_instance.y || (room_min_y + room_height / 2.0)

    # Map character's proportional position in room to arena hex coords
    # Compress to 10%-90% range so edge positions get pushed inward
    pct_x = ((char_x - room_min_x) / room_width).clamp(0.0, 1.0)
    pct_y = ((char_y - room_min_y) / room_height).clamp(0.0, 1.0)
    pct_x = 0.1 + pct_x * 0.8
    pct_y = 0.1 + pct_y * 0.8
    hex_x = (pct_x * hex_max_x).round
    hex_y = (pct_y * hex_max_y).round

    # Clamp to valid arena hex
    hex_x, hex_y = clamp_to_arena(hex_x, hex_y)

    # If landing hex isn't traversable, find nearest traversable one
    unless RoomHex.playable_at?(room, hex_x, hex_y)
      found = find_nearest_traversable(hex_x, hex_y, room)
      hex_x, hex_y = found if found
    end

    # Add 0-1 hex random scatter (70% chance)
    if rand < 0.7
      candidates = hexes_at_distance(hex_x, hex_y, 1)
      candidates.select! { |hx, hy| in_arena?(hx, hy, hex_max_x, hex_max_y) && RoomHex.playable_at?(room, hx, hy) }
      return candidates.sample if candidates.any?
    end

    [hex_x, hex_y]
  end

  # @return [Array<Integer, Integer>] hex_max_x, hex_max_y
  def arena_hex_bounds
    arena_w = fight.arena_width || 10
    arena_h = fight.arena_height || 10
    hex_max_x = [arena_w - 1, 0].max
    hex_max_y = [(arena_h - 1) * 4 + 2, 0].max
    [hex_max_x, hex_max_y]
  end

  # Check if a hex is within arena bounds
  def in_arena?(hx, hy, max_x, max_y)
    hx >= 0 && hx <= max_x && hy >= 0 && hy <= max_y
  end

  def clamp_to_arena(hex_x, hex_y)
    HexGrid.clamp_to_arena(hex_x, hex_y, fight.arena_width, fight.arena_height)
  end

  def process_target_choice(participant, choice)
    target_id = choice.to_i
    target = fight.fight_participants_dataset.where(id: target_id).first
    protected_ids = StatusEffectService.cannot_target_ids(participant)

    if target &&
       target.id != participant.id &&
       !participant.same_side?(target) &&
       !protected_ids.include?(target.id)
      participant.update(target_participant_id: target.id, input_stage: 'main_action')
    else
      # Invalid target, stay on this stage
      participant.update(input_stage: 'main_target')
    end
  end

  def process_main_action_choice(participant, choice)
    action = FightParticipant::MAIN_ACTIONS.include?(choice) ? choice : 'attack'
    next_stage = CombatQuickmenuHandler.next_stage_for('main', participant)
    # Need to set main_action first before calculating next stage
    participant.update(main_action: action)
    # Recalculate next stage after main_action is set
    next_stage = CombatQuickmenuHandler.next_stage_for('main', participant)
    participant.update(input_stage: next_stage)
  end

  def process_ability_choice(participant, choice)
    # Handle new format: "ability_123" (database ID)
    if choice =~ /^ability_(\d+)$/
      ability_id = ::Regexp.last_match(1).to_i
      ability = Ability.where(id: ability_id).first
      if ability && ability_available_for_slot?(participant, ability, :main)
        participant.update(ability_id: ability_id, ability_choice: ability.name.downcase)
      end
    end

    next_stage = CombatQuickmenuHandler.next_stage_for('ability', participant)
    participant.update(input_stage: next_stage)
  end

  def process_tactical_ability_choice(participant, choice)
    if choice == 'skip_tactical_ability'
      # Skip tactical ability
      next_stage = CombatQuickmenuHandler.next_stage_for('tactical_ability', participant)
      participant.update(input_stage: next_stage)
      return
    end

    # Handle "tactical_ability_123" format
    if choice =~ /^tactical_ability_(\d+)$/
      ability_id = ::Regexp.last_match(1).to_i
      ability = Ability.where(id: ability_id).first

      if ability && ability_available_for_slot?(participant, ability, :tactical)
        # Schedule tactical ability - stored separately for processing
        # For now, use ability_target_participant_id to store tactical ability ID
        participant.update(
          tactical_ability_id: ability_id,
          input_stage: CombatQuickmenuHandler.next_stage_for('tactical_ability', participant)
        )
        return
      end
    end

    next_stage = CombatQuickmenuHandler.next_stage_for('tactical_ability', participant)
    participant.update(input_stage: next_stage)
  end

  def process_tactical_choice(participant, choice)
    tactical = FightParticipant::TACTIC_CHOICES.include?(choice) ? choice : nil
    next_stage = CombatQuickmenuHandler.next_stage_for('tactical', participant)
    participant.update(tactic_choice: tactical, input_stage: next_stage)
  end

  # Validate chosen ability against currently available abilities.
  # If availability list is empty (legacy/test flows), allow by fallback.
  def ability_available_for_slot?(participant, ability, slot)
    available = if slot == :tactical
                  participant.available_tactical_abilities
                else
                  participant.available_main_abilities
                end
    available_list = available.respond_to?(:to_a) ? available.to_a : Array(available)
    return true if available_list.empty?

    available_list.any? { |candidate| candidate&.id == ability.id }
  end

  def process_willpower_choice(participant, choice)
    next_stage = CombatQuickmenuHandler.next_stage_for('willpower', participant)

    if choice == 'skip'
      participant.set_willpower_allocation!(attack: 0, defense: 0, ability: 0, movement: 0)
      participant.update(input_stage: next_stage)
      return
    end

    # Parse choice format: "type_count" (e.g., "attack_2")
    match = choice.match(/^(attack|defense|ability|movement)_(\d+)$/)
    unless match
      participant.update(input_stage: next_stage)
      return
    end

    type = match[1]
    count = match[2].to_i

    allocations = { attack: 0, defense: 0, ability: 0, movement: 0 }
    allocations[type.to_sym] = count
    participant.set_willpower_allocation!(**allocations)
    participant.update(input_stage: next_stage)
  end

  def process_movement_choice(participant, choice)
    next_stage = CombatQuickmenuHandler.next_stage_for('movement', participant)

    case choice
    when 'stand_still'
      participant.update(
        movement_action: 'stand_still',
        movement_target_participant_id: nil,
        input_stage: next_stage
      )
    when /^towards_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      participant.update(
        movement_action: 'towards_person',
        movement_target_participant_id: target_id,
        input_stage: next_stage
      )
    when /^away_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      participant.update(
        movement_action: 'away_from',
        movement_target_participant_id: target_id,
        input_stage: next_stage
      )
    when /^maintain_(\d+)_(\d+)$/
      target_id = ::Regexp.last_match(1).to_i
      range = ::Regexp.last_match(2).to_i
      participant.update(
        movement_action: 'maintain_distance',
        movement_target_participant_id: target_id,
        maintain_distance_range: range,
        input_stage: next_stage
      )
    when /^hex_(\d+)_(\d+)$/
      # Store target hex coordinates in dedicated columns
      x = ::Regexp.last_match(1).to_i
      y = ::Regexp.last_match(2).to_i
      participant.update(
        movement_action: 'move_to_hex',
        target_hex_x: x,
        target_hex_y: y,
        input_stage: next_stage
      )
    when /^mount_monster_(\d+)$/
      # Mount a monster
      monster_id = ::Regexp.last_match(1).to_i
      process_mount_action(participant, monster_id)
      participant.update(input_stage: next_stage)
    when 'climb'
      # Climb toward weak point while mounted
      process_climb_action(participant)
      participant.update(mount_action: 'climb', input_stage: next_stage)
    when 'cling'
      # Cling to monster (safe from shake-off)
      process_cling_action(participant)
      participant.update(mount_action: 'cling', input_stage: next_stage)
    when 'dismount'
      # Dismount from monster
      process_dismount_action(participant)
      participant.update(input_stage: next_stage)
    else
      participant.update(
        movement_action: 'stand_still',
        input_stage: next_stage
      )
    end

    # If next stage is 'done', complete input
    participant.complete_input! if next_stage == 'done'
  end

  def process_weapon_choice(participant, choice, weapon_type)
    if choice == 'none' || choice == 'unarmed'
      weapon_id = nil
    else
      weapon = find_weapon_by_id(participant.character_instance, choice.to_i)
      weapon_id = weapon&.id
    end

    if weapon_type == :melee
      participant.update(melee_weapon_id: weapon_id, input_stage: 'weapon_ranged')
    else
      participant.update(ranged_weapon_id: weapon_id)
      participant.complete_input!
    end
  end

  def apply_default_choices(participant)
    # Set target if not set - pick first available enemy
    if participant.target_participant_id.nil?
      first_enemy = fight.active_participants
                         .exclude(id: participant.id)
                         .first
      participant.update(target_participant_id: first_enemy&.id)
    end

    # Set default values for any unset fields
    participant.update(
      main_action: participant.main_action || 'attack',
      movement_action: participant.movement_action || 'stand_still'
    )
  end

  # Find best melee and ranged weapons from inventory
  # Prefers already-equipped weapons, falls back to any in inventory
  # Does NOT equip — equipping happens at attack resolution time
  # Returns [melee_weapon, ranged_weapon] (either may be nil)
  def find_best_weapons(character_instance)
    all_weapons = Item.where(character_instance_id: character_instance.id)
                      .eager(:pattern).all
                      .select { |item| item.pattern&.weapon? }

    melee_options = all_weapons.select { |i| i.pattern.melee_weapon? }
    ranged_options = all_weapons.select { |i| i.pattern.ranged_weapon? }

    best_melee = melee_options.find(&:equipped?) || melee_options.first
    best_ranged = ranged_options.find(&:equipped?) || ranged_options.first

    [best_melee, best_ranged]
  end

  # Apply saved combat preferences for weapons, falling back to auto-selected if unavailable.
  # Notifies the player when a preferred weapon is no longer available.
  def apply_weapon_preferences(character_instance, auto_melee, auto_ranged)
    melee = auto_melee
    ranged = auto_ranged

    pref_melee_id = character_instance.combat_preference(:melee_weapon_id)
    pref_ranged_id = character_instance.combat_preference(:ranged_weapon_id)

    if pref_melee_id
      pref_melee = find_weapon_by_id(character_instance, pref_melee_id)
      if pref_melee
        melee = pref_melee
      else
        fallback_name = auto_melee&.name || 'unarmed'
        BroadcastService.to_character(
          character_instance,
          "Your preferred melee weapon isn't available, using #{fallback_name} instead.",
          type: :system
        )
      end
    end

    if pref_ranged_id
      pref_ranged = find_weapon_by_id(character_instance, pref_ranged_id)
      if pref_ranged
        ranged = pref_ranged
      else
        fallback_name = auto_ranged&.name || 'none'
        BroadcastService.to_character(
          character_instance,
          "Your preferred ranged weapon isn't available, using #{fallback_name} instead.",
          type: :system
        )
      end
    end

    [melee, ranged]
  end

  def find_melee_weapon(character_instance)
    find_best_weapons(character_instance).first
  end

  def find_ranged_weapon(character_instance)
    find_best_weapons(character_instance).last
  end

  def find_weapon_by_id(character_instance, item_id)
    Item.where(id: item_id, character_instance_id: character_instance.id).first
  end

  # Process mount action - participant mounts a monster
  def process_mount_action(participant, monster_id)
    monster = monster_for_fight(monster_id, active_only: true)
    return unless monster

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.attempt_mount(participant, monster)

    if result[:success]
      # Update participant to target the monster
      participant.update(
        targeting_monster_id: monster.id,
        targeting_segment_id: result[:segment]&.id,
        is_mounted: true,
        mount_action: 'cling'  # Default to safe cling
      )
    end
  end

  # Process climb action - mounted participant climbs toward weak point
  def process_climb_action(participant)
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    mounting_service.process_climb(mount_state)
  end

  # Process cling action - mounted participant clings safely
  def process_cling_action(participant)
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    mounting_service.process_cling(mount_state)
  end

  # Process dismount action - participant safely dismounts
  def process_dismount_action(participant)
    return unless participant.is_mounted && participant.targeting_monster_id

    monster = monster_for_fight(participant.targeting_monster_id)
    return unless monster

    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
    return unless mount_state

    mounting_service = MonsterMountingService.new(fight)
    result = mounting_service.process_dismount(mount_state)

    if result[:success]
      participant.update(
        hex_x: result[:landing_position][0],
        hex_y: result[:landing_position][1],
        is_mounted: false,
        targeting_monster_id: nil,
        targeting_segment_id: nil,
        mount_action: nil
      )
    end
  end

  # Resolve monster IDs strictly within this fight.
  def monster_for_fight(monster_id, active_only: false)
    return nil unless monster_id

    dataset = LargeMonsterInstance.where(id: monster_id, fight_id: fight.id)
    dataset = dataset.where(status: 'active') if active_only
    dataset.first
  end

end
