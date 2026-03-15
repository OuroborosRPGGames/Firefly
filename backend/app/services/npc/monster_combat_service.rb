# frozen_string_literal: true

# Main integration service for monster combat.
# Called by CombatResolutionService to schedule and process monster attacks.
class MonsterCombatService
  def initialize(fight)
    @fight = fight
    @segment_events = Hash.new { |h, k| h[k] = [] }
  end

  # Schedule all monster attacks for the 100-segment timeline
  # @param monster [LargeMonsterInstance]
  # @return [Hash<Integer, Array>] segment number => array of events
  def schedule_monster_attacks(monster)
    ai_service = MonsterAIService.new(monster)
    decisions = ai_service.decide_actions

    events = Hash.new { |h, k| h[k] = [] }

    # Schedule turn (5 segments before movement)
    if decisions[:should_turn]
      turn_seg = [decisions[:movement_segment] - 5, 1].max
      events[turn_seg] << {
        type: :monster_turn,
        monster_id: monster.id,
        direction: decisions[:turn_direction]
      }
    end

    # Schedule movement
    if decisions[:should_move] && decisions[:move_target]
      events[decisions[:movement_segment]] << {
        type: :monster_move,
        monster_id: monster.id,
        target_x: decisions[:move_target][0],
        target_y: decisions[:move_target][1]
      }
    end

    # Schedule segment attacks
    decisions[:attacking_segments].each do |segment|
      schedule_segment_attacks(monster, segment, ai_service, events)
    end

    # Schedule shake-off if decided
    if decisions[:should_shake_off] && decisions[:shake_off_segment]
      events[decisions[:shake_off_segment]] << {
        type: :monster_shake_off,
        monster_id: monster.id
      }
    end

    events
  end

  # Process a monster attack event
  # @param event [Hash]
  # @param segment_num [Integer]
  # @return [Hash] event result for narrative
  def process_monster_attack(event, segment_num)
    monster = LargeMonsterInstance[event[:monster_id]]
    return nil unless monster && monster.active?

    segment = MonsterSegmentInstance[event[:segment_id]]
    return nil unless segment && segment.can_attack

    target = FightParticipant[event[:target_id]]
    return nil unless target && !target.is_knocked_out

    ai_service = MonsterAIService.new(monster)

    # Range check
    unless ai_service.segment_can_hit?(segment, target)
      return {
        type: 'monster_attack_miss',
        reason: 'out_of_range',
        segment_name: segment.name,
        target_name: target.character_name
      }
    end

    # Roll damage
    damage = segment.roll_damage

    # Apply NPC damage bonus from archetype
    archetype = monster.monster_template.npc_archetype
    if archetype
      damage += archetype.combat_stats[:damage_bonus].to_i
    end

    # Record the attack
    segment.record_attack!(segment_num)

    # Apply damage type modifiers for monster attacks
    # Monster segments could have custom damage types, default to physical
    damage_type = segment.respond_to?(:damage_type) && segment.damage_type || 'physical'

    # Apply vulnerability/resistance multiplier
    damage = (damage * StatusEffectService.damage_type_multiplier(target, damage_type)).round

    # Apply flat damage reduction
    damage = [damage - StatusEffectService.flat_damage_reduction(target, damage_type), 0].max

    # Absorb damage with shields
    damage = StatusEffectService.absorb_damage_with_shields(target, damage, damage_type)

    # Accumulate damage on target
    target.accumulate_damage!(damage)

    {
      type: 'monster_attack',
      segment_name: segment.name,
      monster_name: monster.display_name,
      target_name: target.character_name,
      damage: damage,
      segment_number: segment_num
    }
  end

  # Process a monster turn event
  # @param event [Hash]
  # @return [Hash] event result for narrative
  def process_monster_turn(event)
    monster = LargeMonsterInstance[event[:monster_id]]
    return nil unless monster && monster.active?

    old_direction = monster.facing_direction || 0
    monster.turn_to(event[:direction])

    {
      type: 'monster_turn',
      monster_name: monster.display_name,
      old_direction: old_direction,
      new_direction: event[:direction]
    }
  end

  # Process a monster movement event
  # @param event [Hash]
  # @return [Hash] event result for narrative
  def process_monster_move(event)
    monster = LargeMonsterInstance[event[:monster_id]]
    return nil unless monster && monster.active?
    return nil if monster.collapsed? # Can't move if collapsed

    old_x = monster.center_hex_x
    old_y = monster.center_hex_y

    # Move monster (also moves mounted characters)
    MonsterHexService.new(monster).move_monster(event[:target_x], event[:target_y])

    {
      type: 'monster_move',
      monster_name: monster.display_name,
      from_x: old_x,
      from_y: old_y,
      to_x: event[:target_x],
      to_y: event[:target_y]
    }
  end

  # Process a shake-off event
  # @param event [Hash]
  # @return [Hash] event result for narrative
  def process_shake_off(event)
    monster = LargeMonsterInstance[event[:monster_id]]
    return nil unless monster && monster.active?

    mounting_service = MonsterMountingService.new(@fight)
    result = mounting_service.process_shake_off(monster)

    # Apply thrown positions
    mounting_service.apply_thrown_positions(monster)

    {
      type: 'monster_shake_off',
      monster_name: monster.display_name,
      thrown_count: result[:thrown_count],
      results: result[:results]
    }
  end

  # Process an attack against a monster (from a player)
  # @param attacker [FightParticipant]
  # @param monster [LargeMonsterInstance]
  # @param damage [Integer] base damage rolled
  # @return [Hash] attack result
  def process_attack_on_monster(attacker, monster, damage)
    mounting_service = MonsterMountingService.new(@fight)
    damage_service = MonsterDamageService.new(monster)

    # Check if attacker is at weak point
    if mounting_service.at_weak_point?(attacker, monster)
      # TRIPLE DAMAGE to all segments!
      return damage_service.apply_weak_point_attack(damage, attacker)
    end

    # Normal attack - target specific segment
    target_segment = mounting_service.target_segment(attacker, monster)

    unless target_segment
      return {
        success: false,
        reason: 'no_target_segment'
      }
    end

    # Check if attacker is mounted on this segment (can hit it)
    # or if attacker is not mounted (can hit closest segment)
    result = damage_service.apply_damage_to_segment(target_segment, damage)

    {
      success: true,
      segment_name: target_segment.name,
      segment_damage: result[:segment_damage],
      segment_status: result[:segment_status],
      monster_hp: result[:monster_hp],
      monster_hp_percent: result[:monster_hp_percent],
      events: result[:events]
    }
  end

  # Get all monsters in the fight
  # @return [Array<LargeMonsterInstance>]
  def monsters_in_fight
    LargeMonsterInstance.where(fight_id: @fight.id, status: 'active').all
  end

  # Check if fight has any active monsters
  # @return [Boolean]
  def has_active_monsters?
    monsters_in_fight.any?
  end

  # Reset all monsters for a new round
  def reset_monsters_for_new_round
    monsters_in_fight.each(&:reset_for_new_round!)
  end

  private

  # Schedule attacks for a specific segment
  def schedule_segment_attacks(monster, segment, ai_service, events)
    template = segment.monster_segment_template
    attack_segments = template.attack_segments

    attack_segments.each do |base_segment|
      # Add randomization (±10%)
      variance = (base_segment * 0.1).round
      randomized = (base_segment + rand(-variance..variance)).clamp(1, 100)

      # Select target for this attack
      target = ai_service.select_target_for_segment(segment)
      next unless target

      events[randomized] << {
        type: :monster_attack,
        monster_id: monster.id,
        segment_id: segment.id,
        target_id: target.id
      }
    end
  end
end
