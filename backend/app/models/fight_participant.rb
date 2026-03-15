# frozen_string_literal: true

# Represents a character participating in a fight.
# HP is sourced from character_instance.health/max_health.
class FightParticipant < Sequel::Model
  include JsonbParsing
  include DamageCalculation
  include StringHelper

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :fight
  many_to_one :character_instance
  many_to_one :target_participant, class: :FightParticipant, key: :target_participant_id
  many_to_one :movement_target_participant, class: :FightParticipant, key: :movement_target_participant_id
  many_to_one :ability_target_participant, class: :FightParticipant, key: :ability_target_participant_id
  many_to_one :melee_weapon, class: :Item, key: :melee_weapon_id
  many_to_one :ranged_weapon, class: :Item, key: :ranged_weapon_id
  many_to_one :selected_ability, class: :Ability, key: :ability_id
  many_to_one :tactical_ability, class: :Ability, key: :tactical_ability_id
  many_to_one :tactic_target_participant, class: :FightParticipant, key: :tactic_target_participant_id
  one_to_many :actor_fight_events, class: :FightEvent, key: :actor_participant_id
  one_to_many :target_fight_events, class: :FightEvent, key: :target_participant_id
  one_to_many :participant_status_effects

  # New hub-style menu stages
  INPUT_STAGES = %w[main_menu main_action main_target tactical_action tactical_target tactical_ability_target movement willpower options autobattle side_select weapon_melee weapon_ranged done].freeze
  MOVEMENT_ACTIONS = %w[move_to_hex towards_person stand_still away_from maintain_distance flee].freeze
  # Old tactics (deprecated): damage_boost, movement_boost, defense_boost
  # New tactics with ally-targeting support
  TACTIC_CHOICES = %w[aggressive defensive quick guard back_to_back].freeze
  MAIN_ACTIONS = %w[attack defend ability dodge stand pass sprint surrender].freeze
  AUTOBATTLE_STYLES = %w[aggressive defensive supportive].freeze

  def validate
    super
    validates_presence [:fight_id]
    # character_instance_id is required unless this is a delve monster NPC
    validates_presence [:character_instance_id] unless is_npc
    validates_includes INPUT_STAGES, :input_stage if input_stage
    validates_includes MOVEMENT_ACTIONS, :movement_action if movement_action
    validates_includes MAIN_ACTIONS, :main_action if main_action
    validates_includes TACTIC_CHOICES, :tactic_choice if present?(tactic_choice)
    validates_includes AUTOBATTLE_STYLES, :autobattle_style if present?(autobattle_style)
    # ability_choice is set by name when ability_id is selected - no standalone validation needed
  end

  def before_create
    super
    # Apply NPC combat stats from archetype if this is an NPC
    apply_npc_combat_stats if character_instance&.character&.npc?
    sync_legacy_hp_assignments_to_character! if values.key?(:current_hp) || values.key?(:max_hp)

    # Ensure the backing CharacterInstance HP fields are initialized.
    initialize_character_health!
    self.willpower_dice ||= GameConfig::Mechanics::WILLPOWER[:initial_dice]
    self.input_stage ||= 'main_menu'
  end

  def before_update
    super
    if changed_columns.include?(:current_hp) || changed_columns.include?(:max_hp)
      sync_legacy_hp_assignments_to_character!
    end
  end

  # Apply combat stats from NPC archetype
  # Sets max_hp, damage/defense bonuses, speed modifier, and damage dice
  def apply_npc_combat_stats
    archetype = character_instance.character.npc_archetype
    return unless archetype

    stats = archetype.combat_stats
    if stats[:max_hp]
      self.max_hp = stats[:max_hp]
      self.current_hp = stats[:max_hp]
    end
    self.npc_damage_bonus = stats[:damage_bonus]
    self.npc_defense_bonus = stats[:defense_bonus]
    self.npc_speed_modifier = stats[:speed_modifier]
    self.npc_damage_dice_count = stats[:damage_dice_count]
    self.npc_damage_dice_sides = stats[:damage_dice_sides]
  end

  # Check if this participant is an NPC with custom damage dice configured
  # @return [Boolean] true if NPC with custom dice
  def npc_with_custom_dice?
    !npc_damage_dice_count.nil? && !npc_damage_dice_sides.nil?
  end

  # === HP & Damage ===

  # Current HP is sourced from character_instance.health.
  # Falls back to legacy column only when no character instance is linked.
  def current_hp
    ci = character_instance
    return ci.health if ci && !ci.health.nil?

    self[:current_hp] || GameConfig::Mechanics::DEFAULT_HP[:current]
  end

  # Max HP is sourced from character_instance.max_health.
  # Falls back to legacy column only when no character instance is linked.
  def max_hp
    ci = character_instance
    return ci.max_health if ci && !ci.max_health.nil?

    self[:max_hp] || GameConfig::Mechanics::DEFAULT_HP[:max]
  end

  # Backward-compatible assignment helper.
  # Prefer CharacterInstance health/max_health as the source of truth.
  def current_hp=(value)
    set_current_hp!(value)
  end

  # Backward-compatible assignment helper.
  # Prefer CharacterInstance health/max_health as the source of truth.
  def max_hp=(value)
    set_max_hp!(value)
  end

  # Calculate roll penalty from wounds (each HP lost = -1)
  # In spar mode, wound penalty is always 0 (touches don't affect rolls)
  def wound_penalty
    return 0 if fight&.spar_mode?
    max_hp - current_hp
  end

  # Check if participant has lost the spar (reached max touches)
  def spar_defeated?
    (touch_count || 0) >= max_hp
  end

  # damage_thresholds and calculate_hp_from_damage are provided by DamageCalculation concern
  # They use wound_penalty (above) which handles spar mode

  # Take damage and apply HP loss + willpower gain
  # Returns the HP actually lost
  def take_damage(total_damage)
    hp_lost = calculate_hp_from_damage(total_damage)

    if hp_lost > 0
      new_hp = [current_hp - hp_lost, 0].max
      wp_config = GameConfig::Mechanics::WILLPOWER
      new_willpower = [(willpower_dice.to_f + (hp_lost * wp_config[:gain_per_hp_lost])), wp_config[:max_dice]].min

      updates = {
        willpower_dice: new_willpower
      }
      updates[:is_knocked_out] = true if new_hp <= 0

      update(updates)
      set_current_hp!(new_hp)
    end

    hp_lost
  end

  # === Incremental Damage System ===
  # Used during round resolution to apply damage incrementally as it accumulates

  # Check cumulative damage against thresholds and return HP that SHOULD be lost
  # Does NOT clear cumulative - damage continues accumulating throughout the round
  # @param cumulative_damage [Integer] total damage accumulated so far this round
  # @return [Integer] HP lost based on current thresholds
  def hp_lost_from_cumulative(cumulative_damage)
    calculate_hp_from_damage(cumulative_damage)
  end

  # Apply HP loss from combat incrementally
  # Only applies the ADDITIONAL HP loss since last check
  # In spar mode: tracks touches instead of HP loss
  # @param new_hp_lost [Integer] total HP that should now be lost this round
  # @param previously_lost [Integer] HP already lost earlier in this round
  # @return [Integer] additional HP lost this check (new_hp_lost - previously_lost)
  def apply_incremental_hp_loss!(new_hp_lost, previously_lost)
    additional_loss = new_hp_lost - previously_lost
    return 0 if additional_loss <= 0

    if fight&.spar_mode?
      # In spar mode: increment touch count, don't touch HP
      new_touch_count = (touch_count || 0) + additional_loss
      update(touch_count: new_touch_count)
      return additional_loss
    end

    # Normal mode: apply HP loss
    new_hp = [current_hp - additional_loss, 0].max

    # Gain willpower per HP lost
    wp_config = GameConfig::Mechanics::WILLPOWER
    new_willpower = [(willpower_dice.to_f + (additional_loss * wp_config[:gain_per_hp_lost])), wp_config[:max_dice]].min

    # Check for knockout
    updates = {
      willpower_dice: new_willpower
    }
    updates[:is_knocked_out] = true if new_hp <= 0

    update(updates)
    set_current_hp!(new_hp)
    additional_loss
  end

  # === Willpower ===

  # Available whole willpower dice
  def available_willpower_dice
    willpower_dice.to_f.floor
  end

  # Total willpower dice currently allocated to this round's actions.
  # Allocations are tracked separately from the remaining willpower pool.
  def allocated_willpower_dice
    total = (willpower_attack || 0) + (willpower_defense || 0) + (willpower_ability || 0)
    total += (willpower_movement || 0)
    total
  end

  # Reconcile willpower allocation and keep the dice pool in sync.
  # Increases consume dice from the pool; decreases refund previously allocated dice.
  #
  # @return [Boolean] true if allocation succeeded
  def set_willpower_allocation!(attack: 0, defense: 0, ability: 0, movement: 0)
    attack_count = attack.to_i
    defense_count = defense.to_i
    ability_count = ability.to_i
    movement_count = movement.to_i

    desired_total = attack_count + defense_count + ability_count + movement_count
    current_total = allocated_willpower_dice
    delta = desired_total - current_total

    return false if delta > 0 && available_willpower_dice < delta

    if delta > 0
      delta.times { use_willpower_die! }
    elsif delta < 0
      refund = -delta
      update(
        willpower_dice: willpower_dice.to_f + refund,
        willpower_dice_used_this_round: [(willpower_dice_used_this_round || 0) - refund, 0].max
      )
    end

    attrs = {
      willpower_attack: attack_count,
      willpower_defense: defense_count,
      willpower_ability: ability_count
    }
    attrs[:willpower_movement] = movement_count
    update(attrs)
    true
  end

  # Use a willpower die (returns true if successful)
  def use_willpower_die!
    return false if available_willpower_dice < 1

    update(
      willpower_dice: willpower_dice.to_f - 1,
      willpower_dice_used_this_round: (willpower_dice_used_this_round || 0) + 1
    )
    true
  end

  # === Attack Speed & Segments ===

  # Get the number of attacks per round based on weapon speed
  def attacks_per_round(weapon)
    base_speed = if weapon&.pattern
                   weapon.pattern.attack_speed || 5
                 else
                   1
                 end

    # Apply NPC speed modifier (clamped to 1-10)
    modifier = npc_speed_modifier || 0
    [base_speed + modifier, 1].max.clamp(1, 10)
  end

  # Calculate attack segments for a weapon with randomization from config
  # Speed 10 = attacks at 10, 20, 30... (10 attacks)
  # Speed 1 = single attack at segment 50
  def attack_segments(weapon)
    speed = attacks_per_round(weapon)
    segments_config = GameConfig::Mechanics::SEGMENTS
    interval = segments_config[:total].to_f / speed

    segments = []
    speed.times do |i|
      base_segment = ((i + 1) * interval).round
      # Apply randomization from config
      variance = (base_segment * segments_config[:attack_randomization]).round
      randomized = base_segment + rand(-variance..variance)
      segments << randomized.clamp(1, segments_config[:total])
    end
    segments.sort
  end

  # === Movement ===

  # Calculate hex distance to another participant
  def hex_distance_to(other)
    return 0 unless other
    return nil if hex_x.nil? || hex_y.nil? || other.hex_x.nil? || other.hex_y.nil?

    HexGrid.hex_distance(hex_x, hex_y, other.hex_x, other.hex_y)
  end

  # Movement speed (total hexes per round)
  # Uses config values for base, sprint, and tactic bonuses
  def movement_speed
    move_config = GameConfig::Mechanics::MOVEMENT
    base = move_config[:base]
    base += move_config[:sprint_bonus] if main_action == 'sprint'
    base += tactic_movement_modifier
    base
  end

  # Calculate movement segments distributed evenly across the round
  # Similar to attack_segments but based on movement speed (hexes per round)
  # Speed 6 = movement steps at segments 17, 33, 50, 67, 83, 100
  # Speed 11 = movement steps at segments 9, 18, 27, 36, 45, 55, 64, 73, 82, 91, 100
  def movement_segments
    hexes = movement_speed
    return [] if hexes <= 0

    segments_config = GameConfig::Mechanics::SEGMENTS
    interval = segments_config[:total].to_f / hexes

    segments = []
    hexes.times do |i|
      base_segment = ((i + 1) * interval).round
      # Apply randomization from config (same as attacks)
      variance = (base_segment * segments_config[:movement_randomization]).round
      randomized = base_segment + rand(-variance..variance)
      segments << randomized.clamp(1, segments_config[:total])
    end
    segments.sort
  end

  # === New Tactic System ===

  # Outgoing damage modifier from tactic choice
  # Uses GameConfig::Tactics::OUTGOING_DAMAGE
  def tactic_outgoing_damage_modifier
    GameConfig::Tactics::OUTGOING_DAMAGE[tactic_choice] || 0
  end

  # Incoming damage modifier from tactic choice
  # Uses GameConfig::Tactics::INCOMING_DAMAGE
  def tactic_incoming_damage_modifier
    GameConfig::Tactics::INCOMING_DAMAGE[tactic_choice] || 0
  end

  # Movement bonus from tactic choice
  # Uses GameConfig::Tactics::MOVEMENT
  def tactic_movement_modifier
    GameConfig::Tactics::MOVEMENT[tactic_choice] || 0
  end

  # Check if this participant is guarding another
  def guarding?(target)
    tactic_choice == 'guard' && tactic_target_participant_id == target.id
  end

  # Check if this participant has back_to_back with another
  def back_to_back_with?(target)
    tactic_choice == 'back_to_back' && tactic_target_participant_id == target.id
  end

  # Check for mutual back_to_back (both targeting each other)
  def mutual_back_to_back_with?(target)
    back_to_back_with?(target) && target.back_to_back_with?(self)
  end

  # Check if protection is active at a given segment (after movement completes)
  def protection_active_at_segment?(segment)
    return true if movement_completed_segment.nil? # If no movement, protection is always active
    segment >= movement_completed_segment
  end

  # Check if this participant requires an adjacent ally target for their tactic
  def tactic_requires_target?
    %w[guard back_to_back].include?(tactic_choice)
  end

  # Get participants who are guarding this participant
  def guarded_by
    fight.active_participants.all.select { |p| p.guarding?(self) }
  end

  # Get participant who has back_to_back with this participant
  def back_to_back_partner
    fight.active_participants.all.find { |p| p.back_to_back_with?(self) }
  end

  # Sync hex position back to character instance's x/y coordinates
  # Hex coordinates are in world space (matching room hex storage)
  # so they can be used directly as feet coordinates
  def sync_position_to_character!
    return unless character_instance

    character_instance.move_to(hex_x.to_f, hex_y.to_f, character_instance.z || 0.0)
  end

  # === Input Management ===

  # Mark input as complete
  def complete_input!
    update(input_complete: true, input_stage: 'done')
  end

  # Advance to the next input stage
  def advance_stage!
    current_index = INPUT_STAGES.index(input_stage) || 0
    next_stage = INPUT_STAGES[current_index + 1] || 'done'
    update(input_stage: next_stage)

    if next_stage == 'done'
      complete_input!
    end
  end

  # === Helpers ===

  # Get character name for display
  # For delve monster NPCs, uses npc_name; for regular characters, uses full_name
  def character_name
    return npc_name if is_npc && npc_name
    character_instance&.character&.full_name || 'Unknown'
  end

  # Short name for compact displays (damage summaries, etc.)
  # Uses nickname or forename instead of full name with surname
  def short_name
    return npc_name if is_npc && npc_name
    char = character_instance&.character
    return 'Unknown' unless char

    char.nickname || char.forename || char.full_name
  end

  # Check if this is a delve monster NPC (no character_instance)
  def delve_monster?
    is_npc && character_instance_id.nil?
  end

  # Check if this participant can act
  def can_act?
    !is_knocked_out
  end

  # Check if in melee range of target
  def in_melee_range?(target)
    hex_distance_to(target) <= 1
  end

  # Get current effective weapon based on distance to target
  def effective_weapon
    return melee_weapon if target_participant.nil?

    if in_melee_range?(target_participant)
      melee_weapon
    else
      ranged_weapon || melee_weapon
    end
  end

  # === Natural Attacks (Archetype-based) ===

  # Get the archetype for this participant's character (if NPC)
  # @return [NpcArchetype, nil]
  def npc_archetype
    character_instance&.character&.npc_archetype
  end

  # Check if this participant is using natural attacks (no weapons, but has archetype attacks)
  # @return [Boolean]
  def using_natural_attacks?
    melee_weapon.nil? && ranged_weapon.nil? && npc_archetype&.has_natural_attacks?
  end

  # Get effective melee attack (weapon or natural attack)
  # @return [Item, NpcAttack, nil]
  def effective_melee_attack
    return melee_weapon if melee_weapon

    npc_archetype&.primary_melee_attack
  end

  # Get effective ranged attack (weapon or natural attack)
  # @return [Item, NpcAttack, nil]
  def effective_ranged_attack
    return ranged_weapon if ranged_weapon

    npc_archetype&.primary_ranged_attack
  end

  # Get the best attack for a given distance
  # Considers both equipped weapons and natural attacks
  # @param distance [Integer] Distance in hexes
  # @return [Item, NpcAttack, nil]
  def best_attack_for_distance(distance)
    # Prefer equipped weapons
    if distance <= 1 && melee_weapon
      return melee_weapon
    elsif distance > 1 && ranged_weapon
      return ranged_weapon
    elsif melee_weapon || ranged_weapon
      return melee_weapon || ranged_weapon
    end

    # Fall back to natural attacks from archetype
    npc_archetype&.best_attack_for_range(distance)
  end

  # Get attack segments for a natural attack
  # @param attack [NpcAttack] The natural attack
  # @return [Array<Integer>] Segments when attacks occur
  def natural_attack_segments(attack)
    speed = attack.attack_speed
    segments_config = GameConfig::Mechanics::SEGMENTS
    interval = segments_config[:total].to_f / speed

    segments = []
    speed.times do |i|
      base_segment = ((i + 1) * interval).round
      variance = (base_segment * segments_config[:attack_randomization]).round
      randomized = base_segment + rand(-variance..variance)
      segments << randomized.clamp(1, segments_config[:total])
    end
    segments.sort
  end

  # Check if this participant has any attack capability
  # @return [Boolean]
  def has_any_attack?
    melee_weapon || ranged_weapon || npc_archetype&.has_natural_attacks?
  end
  alias any_attack? has_any_attack?

  # === Side/Team System ===

  # Get allies on the same side (excluding self)
  # @return [Array<FightParticipant>] allies on same side
  def allies
    fight.active_participants
         .where(side: side)
         .exclude(id: id)
         .where(is_knocked_out: false)
         .all
  end

  # Get enemies on other sides
  # @return [Array<FightParticipant>] enemies on different sides
  def enemies
    fight.active_participants
         .exclude(side: side)
         .where(is_knocked_out: false)
         .all
  end

  # Check if on the same side as another participant
  # @param other [FightParticipant] the other participant to check
  # @return [Boolean] true if on same side
  def same_side?(other)
    return false unless other.respond_to?(:side)

    side == other.side
  end

  # Accumulate damage from an incoming attack
  def accumulate_damage!(damage)
    update(
      pending_damage_total: (pending_damage_total || 0) + damage,
      incoming_attack_count: (incoming_attack_count || 0) + 1
    )
  end

  # Clear accumulated damage after applying
  def clear_accumulated_damage!
    update(pending_damage_total: 0, incoming_attack_count: 0)
  end

  # === Ability System ===

  # Calculate ability damage roll (e.g., Fireball)
  # @return [Integer] the damage roll result
  def ability_damage_roll(_ability_name)
    dice_config = GameConfig::Mechanics::DICE
    base_roll = rand(1..dice_config[:pc_sides]) + rand(1..dice_config[:pc_sides])
    stat_mod = intelligence_modifier
    # Legacy ability_cooldown_penalty is deprecated; only JSONB penalties apply.
    penalty = total_ability_penalty
    willpower_bonus = (willpower_ability || 0) * GameConfig::Mechanics::WILLPOWER[:bonus_per_die]

    [base_roll + stat_mod + penalty + willpower_bonus, 0].max
  end

  # Get Intelligence modifier from character stats
  # @return [Integer] the Intelligence stat value
  def intelligence_modifier
    stat_modifier('Intelligence')
  end

  # Calculate defense roll from willpower dice with exploding on 8
  # @return [Hash] the roll result from DiceRollService with :total, :rolls, :exploded
  def willpower_defense_roll
    dice_count = willpower_defense || 0
    return nil if dice_count == 0

    DiceRollService.roll(dice_count, 8, explode_on: 8, modifier: 0)
  end

  # Roll additional attack dice from willpower
  # Each willpower die adds another d8 that explodes on 8
  # @return [RollResult, nil] the roll result, or nil if no dice allocated
  def willpower_attack_roll
    dice_count = willpower_attack || 0
    return nil if dice_count == 0

    DiceRollService.roll(dice_count, 8, explode_on: 8, modifier: 0)
  end

  # Roll additional ability dice from willpower
  # Each willpower die adds another d8 that explodes on 8
  # @return [RollResult, nil] the roll result, or nil if no dice allocated
  def willpower_ability_roll
    dice_count = willpower_ability || 0
    return nil if dice_count == 0

    DiceRollService.roll(dice_count, 8, explode_on: 8, modifier: 0)
  end

  # Roll willpower dice for movement bonus
  # Rolls Xd8 (exploding) and returns half the total as bonus movement hexes
  # @return [Hash, nil] { roll_result: RollResult, bonus_hexes: Integer }, or nil if no dice allocated
  def willpower_movement_roll
    dice_count = willpower_movement || 0
    return nil if dice_count == 0

    roll_result = DiceRollService.roll(dice_count, 8, explode_on: 8, modifier: 0)
    bonus_hexes = (roll_result.total / 2.0).floor

    { roll_result: roll_result, bonus_hexes: bonus_hexes }
  end

  # Legacy compatibility - get attack bonus as integer (deprecated, use willpower_attack_roll)
  # @return [Integer] the attack bonus total
  def willpower_attack_bonus
    roll = willpower_attack_roll
    roll&.total || 0
  end

  # Legacy compatibility - get ability bonus as integer (deprecated, use willpower_ability_roll)
  # @return [Integer] the ability bonus total
  def willpower_ability_bonus
    roll = willpower_ability_roll
    roll&.total || 0
  end

  # Reset willpower allocations for new round
  def reset_willpower_allocations!
    attrs = {
      willpower_attack: 0,
      willpower_defense: 0,
      willpower_ability: 0,
      ability_choice: nil,
      ability_id: nil
    }
    attrs[:willpower_movement] = 0
    update(attrs)
  end

  # Reset menu state for new round (hub-style menu tracking)
  def reset_menu_state!
    update(
      main_action_set: false,
      tactical_action_set: false,
      movement_set: false,
      willpower_set: false,
      pending_action_name: nil,
      input_stage: 'main_menu',
      input_complete: false,
      # Reset new tactic system fields
      tactic_choice: nil,
      tactic_target_participant_id: nil,
      tactical_ability_id: nil,
      movement_completed_segment: nil
    )
  end

  # === Enhanced Penalty System (JSONB-based) ===

  # Parse roll penalties from JSONB
  # @return [Hash] parsed penalties
  def parsed_roll_penalties
    parse_jsonb_hash(roll_penalties)
  end

  # Get ability-specific roll penalty
  # @return [Integer] penalty amount (negative value)
  def ability_roll_penalty
    parsed_roll_penalties.dig('ability_rolls', 'amount').to_i
  end

  # Get all-roll penalty (applies to everything)
  # @return [Integer] penalty amount (negative value)
  def all_roll_penalty
    parsed_roll_penalties.dig('all_rolls', 'amount').to_i
  end

  # Get total attack penalty (wound + all-roll)
  # @return [Integer] total penalty
  def total_attack_penalty
    wound_penalty + all_roll_penalty.abs
  end

  # Get total ability penalty (ability_rolls + all_rolls)
  # @return [Integer] total penalty
  def total_ability_penalty
    ability_roll_penalty + all_roll_penalty
  end

  # Apply penalties from an ability's cost configuration
  # @param ability [Ability] the ability used
  def apply_ability_costs!(ability)
    # Handle ability penalty
    if ability.ability_penalty_config.any?
      apply_penalty!(
        'ability_rolls',
        ability.ability_penalty_config['amount'].to_i,
        ability.ability_penalty_config['decay_per_round'].to_i
      )
    end

    # Handle all-roll penalty
    if ability.all_roll_penalty_config.any?
      apply_penalty!(
        'all_rolls',
        ability.all_roll_penalty_config['amount'].to_i,
        ability.all_roll_penalty_config['decay_per_round'].to_i
      )
    end

    # Handle specific cooldown
    if ability.specific_cooldown_rounds > 0
      set_ability_cooldown!(ability.name, ability.specific_cooldown_rounds)
    end

    # Handle global cooldown
    if ability.global_cooldown_rounds > 0
      update(global_ability_cooldown: ability.global_cooldown_rounds)
    end
  end

  # Apply a specific penalty type
  # @param penalty_type [String] 'ability_rolls' or 'all_rolls'
  # @param amount [Integer] penalty amount (should be negative)
  # @param decay [Integer] decay per round
  def apply_penalty!(penalty_type, amount, decay)
    penalties = parsed_roll_penalties
    penalties[penalty_type] = {
      'amount' => amount,
      'decay_per_round' => decay
    }
    update(roll_penalties: Sequel.pg_jsonb_wrap(penalties))
  end

  # Decay all penalties at round start
  def decay_all_penalties!
    penalties = parsed_roll_penalties
    return if penalties.empty?

    changed = false

    # Decay ability penalty
    if penalties['ability_rolls']
      current = penalties['ability_rolls']['amount'].to_i
      decay = penalties['ability_rolls']['decay_per_round'].to_i
      new_amount = [current + decay, 0].min

      if new_amount >= 0
        penalties.delete('ability_rolls')
      else
        penalties['ability_rolls']['amount'] = new_amount
      end
      changed = true
    end

    # Decay all-roll penalty
    if penalties['all_rolls']
      current = penalties['all_rolls']['amount'].to_i
      decay = penalties['all_rolls']['decay_per_round'].to_i
      new_amount = [current + decay, 0].min

      if new_amount >= 0
        penalties.delete('all_rolls')
      else
        penalties['all_rolls']['amount'] = new_amount
      end
      changed = true
    end

    update(roll_penalties: Sequel.pg_jsonb_wrap(penalties)) if changed
  end

  # === Enhanced Cooldown System (JSONB-based) ===

  # Parse ability cooldowns from JSONB
  # @return [Hash] ability name => rounds remaining
  def parsed_ability_cooldowns
    parse_jsonb_hash(ability_cooldowns)
  end

  # Set cooldown for a specific ability
  # @param ability_name [String] name of the ability
  # @param rounds [Integer] rounds of cooldown
  def set_ability_cooldown!(ability_name, rounds)
    cooldowns = parsed_ability_cooldowns
    cooldowns[ability_name] = rounds
    update(ability_cooldowns: Sequel.pg_jsonb_wrap(cooldowns))
  end

  # Get remaining cooldown for a specific ability
  # @param ability_name [String] name of the ability
  # @return [Integer] rounds remaining (0 if not on cooldown)
  def cooldown_for(ability_name)
    parsed_ability_cooldowns[ability_name].to_i
  end

  # Check if a specific ability is on cooldown
  # @param ability [Ability] the ability to check
  # @return [Boolean] true if on cooldown
  def ability_on_cooldown?(ability)
    return true if global_ability_cooldown.to_i > 0

    cooldown_for(ability.name) > 0
  end

  # Check if an ability is available to use
  # @param ability [Ability] the ability to check
  # @return [Boolean] true if available
  def ability_available?(ability)
    !ability_on_cooldown?(ability)
  end

  # Apply cooldown penalty after using an ability
  def apply_ability_cooldown!
    update(ability_cooldown_penalty: GameConfig::Mechanics::COOLDOWNS[:ability_penalty])
  end

  # Decay the global ability cooldown penalty toward 0
  # Penalty is negative after using an ability and decays toward 0 each round.
  def decay_ability_cooldown!
    current = ability_cooldown_penalty || 0
    return if current >= 0

    new_val = [current + GameConfig::Mechanics::COOLDOWNS[:decay_per_round], 0].min
    update(ability_cooldown_penalty: new_val)
  end

  # Decay all ability cooldowns at round start
  def decay_ability_cooldowns!
    cooldowns = parsed_ability_cooldowns

    # Decay specific cooldowns
    cooldowns.each do |ability_name, rounds|
      new_rounds = rounds.to_i - 1
      if new_rounds <= 0
        cooldowns.delete(ability_name)
      else
        cooldowns[ability_name] = new_rounds
      end
    end

    # Decay global cooldown
    new_global = [(global_ability_cooldown || 0) - 1, 0].max

    update(
      ability_cooldowns: Sequel.pg_jsonb_wrap(cooldowns),
      global_ability_cooldown: new_global
    )
  end

  # === Available Abilities ===

  # Get all abilities available to this participant (not on cooldown)
  # @return [Array<Ability>] available abilities
  def available_abilities
    all_combat_abilities.select { |a| ability_available?(a) }
  end

  # Get all combat abilities this character has access to
  # Returns abilities assigned via CharacterAbility (learning system)
  # @return [Array<Ability>] all combat abilities the character knows
  def all_combat_abilities
    return [] unless character_instance

    character_instance.ability_service.abilities_by_type('combat')
  end

  # Get main action abilities available
  # @return [Array<Ability>] abilities that use main action slot
  def available_main_abilities
    available_abilities.select(&:main_action?)
  end

  # Get tactical action abilities available
  # @return [Array<Ability>] abilities that use tactical action slot
  def available_tactical_abilities
    available_abilities.select(&:tactical_action?)
  end

  # === Stat Lookups ===

  # Get a stat modifier by name (cached per instance to avoid N+1 queries)
  # @param stat_name [String] name of the stat (e.g., "Intelligence", "Strength")
  # @return [Integer] the stat value (default 10)
  def stat_modifier(stat_name)
    @cached_stats ||= load_all_stats
    @cached_stats[stat_name.downcase] || GameConfig::Mechanics::DEFAULT_STAT
  end

  # Clear cached stats (call when stats change mid-fight, e.g., status effects)
  def clear_stat_cache!
    @cached_stats = nil
  end

  private

  # Load all stats in a single query and cache as { lowercase_name => value }
  def load_all_stats
    return {} unless character_instance

    CharacterStat
      .eager(:stat)
      .where(character_instance_id: character_instance.id)
      .all
      .each_with_object({}) do |cs, hash|
        name = cs.stat&.name&.downcase
        hash[name] = cs.current_value if name
      end
  end

  public

  # Convenience methods for common stats
  def strength_modifier
    stat_modifier('Strength')
  end

  def dexterity_modifier
    stat_modifier('Dexterity')
  end

  # === Status Effects ===

  # Check if this participant can move (not snared)
  # @return [Boolean] true if can move
  def can_move?
    StatusEffectService.can_move?(self)
  end

  # Get incoming damage modifier from status effects
  # @return [Integer] modifier to add to each incoming attack
  def incoming_damage_modifier
    StatusEffectService.incoming_damage_modifier(self)
  end

  # Get outgoing damage modifier from status effects
  # @return [Integer] modifier to add to each outgoing attack
  def outgoing_damage_modifier
    StatusEffectService.outgoing_damage_modifier(self)
  end

  # Get all active status effects
  # @return [Array<ParticipantStatusEffect>] active effects
  def active_status_effects
    StatusEffectService.active_effects(self)
  end

  # Check if participant has a specific status effect
  # @param effect_name [String] name of the effect
  # @return [Boolean] true if has effect
  def has_status_effect?(effect_name)
    StatusEffectService.has_effect?(self, effect_name)
  end

  # === Healing ===

  # Heal HP
  # @param amount [Integer] HP to restore
  # @return [Integer] HP actually restored
  def heal!(amount)
    # Apply healing modifier from status effects (amplified/reduced healing)
    healing_mult = StatusEffectService.healing_modifier(self)
    modified_amount = (amount * healing_mult).round

    old_hp = current_hp
    new_hp = [current_hp + modified_amount, max_hp].min
    set_current_hp!(new_hp)
    new_hp - old_hp
  end

  # === Round Counters (for conditional damage) ===

  # Get attacks made this round
  # @return [Integer] number of attacks made
  def attacks_this_round
    @attacks_this_round || 0
  end

  # Increment attack counter
  def increment_attacks!
    @attacks_this_round = attacks_this_round + 1
  end

  # Reset all round-specific counters
  def reset_round_counters!
    @attacks_this_round = 0
  end

  # Knockout the participant instantly (for execute mechanics)
  def knockout!
    set_current_hp!(0)
    update(is_knocked_out: true)
  end

  # Sync current HP back to the character instance (the one true HP pool).
  # HP is already sourced from character_instance.health/max_health, so this
  # remains as a backward-compatible no-op.
  def sync_hp_to_character!
    true
  rescue StandardError => e
    warn "[FightParticipant] HP sync failed: #{e.message}"
  end

  # Set HP defaults on linked character instances.
  def initialize_character_health!
    ci = character_instance
    return unless ci

    target_max = ci.max_health || GameConfig::Mechanics::DEFAULT_HP[:max]
    target_current = ci.health || target_max
    attrs = {}
    attrs[:max_health] = target_max if ci.max_health.nil?
    attrs[:health] = target_current if ci.health.nil?
    ci.update(attrs) if attrs.any?
  rescue StandardError => e
    warn "[FightParticipant] HP initialization failed: #{e.message}"
  end

  # Keep legacy fight_participants HP column assignments in sync with
  # character_instance.health/max_health.
  def sync_legacy_hp_assignments_to_character!
    ci = character_instance
    return unless ci

    max_from_row = self[:max_hp]
    current_from_row = self[:current_hp]

    normalized_max = nil
    attrs = {}
    ci_max = ci.max_health
    ci_health = ci.health
    unless max_from_row.nil?
      normalized_max = [max_from_row.to_i, 1].max
      attrs[:max_health] = normalized_max if ci_max != normalized_max
    end

    unless current_from_row.nil?
      max_for_current = normalized_max || ci_max || GameConfig::Mechanics::DEFAULT_HP[:max]
      normalized_current = [[current_from_row.to_i, 0].max, max_for_current.to_i].min
      attrs[:health] = normalized_current if ci_health != normalized_current
    end

    if attrs[:max_health] && attrs[:health].nil? && ci_health && ci_health > attrs[:max_health]
      attrs[:health] = attrs[:max_health]
    end

    ci.update(attrs) if attrs.any?
  rescue StandardError => e
    warn "[FightParticipant] Legacy HP sync failed: #{e.message}"
  end

  # Write current HP to CharacterInstance (source of truth).
  def set_current_hp!(value)
    normalized = [value.to_i, 0].max
    ci = character_instance

    if ci
      max = ci.max_health || max_hp
      normalized = [normalized, max.to_i].min if max
      ci.update(health: normalized)
    else
      self[:current_hp] = normalized
    end

    normalized
  rescue StandardError => e
    warn "[FightParticipant] Set current HP failed: #{e.message}"
    current_hp
  end

  # Write max HP to CharacterInstance (source of truth).
  def set_max_hp!(value)
    normalized = [value.to_i, 1].max
    ci = character_instance

    if ci
      attrs = { max_health: normalized }
      ci_health = ci.health
      if ci_health.nil? || ci_health > normalized
        attrs[:health] = normalized
      end
      ci.update(attrs)
    else
      self[:max_hp] = normalized
      self[:current_hp] = normalized if self[:current_hp].to_i > normalized
    end

    normalized
  rescue StandardError => e
    warn "[FightParticipant] Set max HP failed: #{e.message}"
    max_hp
  end

  # ============================================
  # Flee System
  # ============================================

  # Check if participant is at an arena edge
  # @return [Boolean] true if at arena boundary
  def at_arena_edge?
    return false unless fight && hex_x && hex_y

    max_x = [fight.arena_width - 1, 0].max
    max_y = [(fight.arena_height - 1) * 4 + 2, 0].max

    hex_x == 0 || hex_x == max_x || hex_y == 0 || hex_y == max_y
  end

  # Get which edges the participant is at
  # @return [Array<Symbol>] edges like [:north, :west] for corner
  def arena_edges
    edges = []
    return edges unless fight && hex_x && hex_y

    max_x = [fight.arena_width - 1, 0].max
    max_y = [(fight.arena_height - 1) * 4 + 2, 0].max

    edges << :north if hex_y == 0
    edges << :south if hex_y == max_y
    edges << :west if hex_x == 0
    edges << :east if hex_x == max_x
    edges
  end

  # Get available flee exits based on position
  # Uses spatial adjacency - rooms connect based on polygon geometry
  # @return [Array<Hash>] array of {direction:, exit:} hashes where exit is the destination Room
  def available_flee_exits
    return [] unless at_arena_edge? && fight&.room

    arena_edges.filter_map do |edge|
      destination = RoomAdjacencyService.resolve_direction_movement(fight.room, edge)
      { direction: edge.to_s, exit: destination } if destination
    end
  end

  # Check if flee is available
  # @return [Boolean] true if at edge with valid exit
  def can_flee?
    at_arena_edge? && available_flee_exits.any?
  end

  # Process successful flee - remove from combat and move to adjacent room
  def process_successful_flee!
    return unless is_fleeing && flee_direction

    # Get destination room from flee direction via spatial adjacency
    destination = RoomAdjacencyService.resolve_direction_movement(
      fight.room, flee_direction.to_sym
    )
    return unless destination

    update(is_knocked_out: true)

    if character_instance
      character_instance.update(
        current_room_id: destination.id,
        fled_from_fight_id: fight_id
      )
      # Position character at entry point based on flee direction
      arrival_pos = calculate_flee_arrival_position(destination, flee_direction)
      if arrival_pos
        character_instance.move_to(arrival_pos[0], arrival_pos[1], arrival_pos[2] || 0)
      end
    end
  end

  # Calculate arrival position when fleeing into a room
  def calculate_flee_arrival_position(room, direction)
    case direction.to_s
    when 'north'
      [(room.min_x + room.max_x) / 2.0, room.min_y + 2.0, 0]
    when 'south'
      [(room.min_x + room.max_x) / 2.0, room.max_y - 2.0, 0]
    when 'east'
      [room.min_x + 2.0, (room.min_y + room.max_y) / 2.0, 0]
    when 'west'
      [room.max_x - 2.0, (room.min_y + room.max_y) / 2.0, 0]
    else
      [(room.min_x + room.max_x) / 2.0, (room.min_y + room.max_y) / 2.0, 0]
    end
  end

  # Cancel flee attempt (took damage or chose differently)
  def cancel_flee!
    update(is_fleeing: false, flee_direction: nil)
  end

  # ============================================
  # Surrender System
  # ============================================

  # Process a successful surrender
  def process_surrender!
    update(is_knocked_out: true, is_surrendering: false)

    if character_instance
      character_instance.update(surrendered_from_fight_id: fight_id)
      PrisonerService.process_surrender!(character_instance)
    end
  end

  # Cancel surrender attempt (if needed for any reason)
  def cancel_surrender!
    update(is_surrendering: false)
  end

  # ============================================
  # Autobattle System
  # ============================================

  # Check if autobattle is enabled for this participant
  # @return [Boolean] true if autobattle is enabled
  def autobattle_enabled?
    present?(autobattle_style)
  end

  # Disable autobattle mode
  def disable_autobattle!
    update(autobattle_style: nil)
  end

  # Enable autobattle with a specific style
  # @param style [String] 'aggressive', 'defensive', or 'supportive'
  def enable_autobattle!(style)
    update(autobattle_style: style) if AUTOBATTLE_STYLES.include?(style)
  end

  # Get top N most powerful abilities by base power
  # Used to determine when to spend all willpower dice
  # @param count [Integer] number of abilities to return (default 2)
  # @return [Array<Ability>] the most powerful abilities
  def top_powerful_abilities(count = 2)
    abilities = all_combat_abilities
    return [] if abilities.empty?

    sorted = abilities.sort_by { |a| -a.power }
    sorted.first(count)
  end
end
