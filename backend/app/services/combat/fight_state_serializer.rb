# frozen_string_literal: true

module Combat
  # Serializes a Fight and its participants into the hash structure expected
  # by the Rust combat-engine's FightState type. Kept as a service to avoid
  # bloating the Fight model.
  #
  # Rust serde representation notes:
  #   - MovementAction / MainAction / TacticChoice use externally-tagged enums
  #     e.g. { "TowardsPerson" => 2 }, { "Attack" => { "target_id" => 5 } }
  #   - DamageType, FightMode, etc. are simple string enums ("Physical", "Spar")
  class FightStateSerializer
    def initialize(fight)
      @fight = fight
    end

    # Produce the full engine state hash.
    # @return [Hash] FightState for the Rust engine
    def serialize
      {
        'round' => @fight.round_number,
        'fight_mode' => @fight.spar_mode? ? 'Spar' : 'Normal',
        'participants' => serialize_participants,
        'hex_map' => serialize_hex_map,
        'monsters' => serialize_monsters,
        'observer_effects' => serialize_observer_effects,
        'interactive_objects' => serialize_interactive_objects,
        'fight_hexes' => serialize_fight_hexes,
        'window_positions' => serialize_window_positions,
        'status_effect_templates' => serialize_status_effect_templates,
        'wall_mask' => serialize_wall_mask,
        'config' => {} # Use Rust defaults (mirrors GameConfig)
      }
    end

    # Serialize player/NPC actions for the current round.
    # @return [Array<Hash>] PlayerAction list
    def serialize_actions
      @fight.active_participants.map { |p| serialize_action(p) }
    end

    private

    # ── Participants ──────────────────────────────────────────────

    def serialize_participants
      @fight.fight_participants.map { |p| serialize_participant(p) }
    end

    def serialize_participant(p)
      melee = serialize_weapon(p.melee_weapon, p) || default_unarmed_weapon(p)
      {
        'id' => p.id,
        'side' => p.side.to_i,
        'current_hp' => p.current_hp.to_i,
        'max_hp' => p.max_hp.to_i,
        'touch_count' => (p.touch_count || 0).to_i,
        'qi_dice' => p.willpower_dice.to_f,
        'qi_die_sides' => 8,
        'position' => { 'x' => p.hex_x.to_i, 'y' => p.hex_y.to_i, 'z' => participant_elevation(p) },
        'melee_weapon' => melee,
        'ranged_weapon' => serialize_weapon(p.ranged_weapon, p),
        'natural_attacks' => serialize_natural_attacks(p),
        'abilities' => serialize_abilities(p),
        'cooldowns' => serialize_cooldowns(p),
        'combat_style' => serialize_combat_style(p),
        'stat_modifier' => effective_stat_modifier(p, 'Strength'),
        'dexterity_modifier' => effective_stat_modifier(p, 'Dexterity'),
        'all_roll_penalty' => p.all_roll_penalty.to_i,
        'npc_damage_bonus' => (p.npc_damage_bonus || 0).to_i,
        'npc_defense_bonus' => (p.npc_defense_bonus || 0).to_i,
        'global_cooldown' => (p.respond_to?(:global_ability_cooldown) ? (p.global_ability_cooldown || 0) : 0).to_i,
        'ability_roll_penalty' => (p.respond_to?(:ability_roll_penalty) ? (p.ability_roll_penalty || 0) : 0).to_i,
        'outgoing_damage_modifier' => compute_outgoing_modifier(p),
        'incoming_damage_modifier' => compute_incoming_modifier(p),
        # Ruby tactic modifiers are stub methods returning 0 today
        # (fight_participant.rb:370/378), but Ruby's calculate_attack_damage
        # still reads them — serialize so Rust matches the contract.
        'tactic_outgoing_damage_modifier' => (p.respond_to?(:tactic_outgoing_damage_modifier) ? p.tactic_outgoing_damage_modifier.to_i : 0),
        'tactic_incoming_damage_modifier' => (p.respond_to?(:tactic_incoming_damage_modifier) ? p.tactic_incoming_damage_modifier.to_i : 0),
        # Firefly's `quick` tactic adds +2 flat movement via GameConfig::Tactics::MOVEMENT
        # (fight_participant.rb:361-363). Rust's Participant.tactic_movement_bonus_flat
        # gets added to the per-round movement budget alongside dice-derived bonus.
        # Clamp to >=0: Rust's field is u32, and no Firefly tactic produces a negative bonus.
        'tactic_movement_bonus_flat' => (p.respond_to?(:tactic_movement_modifier) ? [p.tactic_movement_modifier.to_i, 0].max : 0),
        'status_effects' => serialize_status_effects(p),
        'ai_profile' => determine_ai_profile(p),
        'is_knocked_out' => p.is_knocked_out || false,
        'is_prone' => participant_is_prone?(p),
        'is_mounted' => p.is_mounted || false,
        'mount_target_id' => p.respond_to?(:targeting_monster_id) ? p.targeting_monster_id : nil,
        'mount_action' => p.respond_to?(:mount_action) ? p.mount_action : nil,
        'is_npc_custom_dice' => p.respond_to?(:npc_with_custom_dice?) ? p.npc_with_custom_dice? : false,
        'is_npc' => p.is_npc ? true : false,
        # Hostile NPC: Ruby routes 0-HP to NpcSpawnService.kill_npc! (character.rb:624).
        # Rust encodes this via KoReason::Died so apply_rust_result! can dispatch.
        'is_hostile_npc' => (p.is_npc && p.character_instance&.character&.hostile?) ? true : false,
        # Queued style switch — Rust emits StyleSwitched at end of round; Ruby
        # writeback invokes apply_style_switch! so the DB, variant lock, and
        # character_instance preference all move together.
        'pending_style_switch' => (p.respond_to?(:pending_style_switch) ? p.pending_style_switch : nil),
        'climb_back_x' => climb_back_coord(p, 'climb_back_x'),
        'climb_back_y' => climb_back_coord(p, 'climb_back_y'),
        'current_target_id' => p.respond_to?(:target_participant_id) ? p.target_participant_id : nil,
        'qi_lightness_elevated' => p.respond_to?(:qi_lightness_elevated) ? (p.qi_lightness_elevated || false) : false,
        'qi_lightness_elevation_bonus' => p.respond_to?(:qi_lightness_elevation_bonus) ? (p.qi_lightness_elevation_bonus || 0).to_i : 0
      }
    end

    # Ruby stores the dangling-climb-back destination in tactic_target_data JSONB
    # (fight_hex_effect_service.rb:378). Extract it for the Rust resolver.
    def climb_back_coord(p, key)
      return nil unless p.respond_to?(:parsed_tactic_target_data)
      data = p.parsed_tactic_target_data
      return nil unless data.is_a?(Hash)
      v = data[key]
      v.nil? ? nil : v.to_i
    rescue StandardError
      nil
    end

    def participant_elevation(p)
      return 0 unless @fight.room&.has_battle_map

      @hex_elevation_cache ||= begin
        cache = {}
        @fight.room.room_hexes.each do |h|
          cache[[h.hex_x.to_i, h.hex_y.to_i]] = (h.respond_to?(:elevation_level) ? (h.elevation_level || 0) : 0).to_i
        end
        cache
      end
      @hex_elevation_cache[[p.hex_x.to_i, p.hex_y.to_i]] || 0
    rescue StandardError
      0
    end

    def participant_is_prone?(p)
      effects = p.respond_to?(:active_status_effects) ? p.active_status_effects : []
      effects.any? do |pse|
        se = pse.status_effect
        se&.effect_type == 'movement' && se&.parsed_mechanics&.dig('prone')
      end
    rescue StandardError
      false
    end

    def effective_stat_modifier(p, stat_name = 'Strength')
      p.stat_modifier(stat_name).to_i
    rescue StandardError
      0
    end

    def compute_outgoing_modifier(p)
      effects = p.respond_to?(:active_status_effects) ? p.active_status_effects : []
      effects.sum do |pse|
        se = pse.status_effect
        next 0 unless se&.effect_type == 'outgoing_damage'

        m = se.parsed_mechanics
        (m['bonus'].to_i * (pse.stack_count || 1))
      end
    rescue StandardError
      0
    end

    def compute_incoming_modifier(p)
      effects = p.respond_to?(:active_status_effects) ? p.active_status_effects : []
      effects.sum do |pse|
        se = pse.status_effect
        next 0 unless se&.effect_type == 'incoming_damage'

        m = se.parsed_mechanics
        (m['modifier'].to_i * (pse.stack_count || 1))
      end
    rescue StandardError
      0
    end

    def serialize_combat_style(p)
      return nil unless p.respond_to?(:active_style) && p.active_style

      style = p.active_style
      return nil unless style.respond_to?(:name)

      bonuses = p.respond_to?(:style_bonuses) ? p.style_bonuses : {}
      defense = p.respond_to?(:style_defense_data) ? p.style_defense_data : {}
      {
        'id' => style.respond_to?(:id) ? style.id : 0,
        'name' => style.name.to_s,
        'bonus_type' => bonuses[:bonus_type] ? damage_type_string(bonuses[:bonus_type]) : nil,
        # Rust defense.rs still reads `bonus_amount` for defensive logic, so
        # keep it populated (either-or). Ruby applies the attack bonus based on
        # weapon type at damage time (combat_resolution_service.rb:2964-2969),
        # so Rust needs both melee and ranged separately too.
        'bonus_amount' => (bonuses[:melee] || bonuses[:ranged] || 0).to_i,
        'melee_bonus' => (bonuses[:melee] || 0).to_i,
        'ranged_bonus' => (bonuses[:ranged] || 0).to_i,
        'vulnerability_type' => defense[:vulnerability_type] ? damage_type_string(defense[:vulnerability_type]) : nil,
        'vulnerability_amount' => (defense[:vulnerability_amount] || 0.0).to_f,
        # Threshold bonuses shift the wound-threshold ladder. Ruby:
        # fight_participant.rb:661 damage_thresholds uses these.
        'threshold_1hp' => (bonuses[:threshold_1hp] || 0).to_i,
        'threshold_2_3hp' => (bonuses[:threshold_2_3hp] || 0).to_i
      }
    rescue StandardError
      nil
    end

    # ── Weapons ──────────────────────────────────────────────────

    def serialize_weapon(weapon, participant)
      return nil unless weapon

      pattern = weapon.respond_to?(:pattern) ? weapon.pattern : nil
      dice_count = if participant.respond_to?(:npc_damage_dice_count) && participant.npc_with_custom_dice?
                     participant.npc_damage_dice_count.to_i
                   else
                     2
                   end
      dice_sides = if participant.respond_to?(:npc_damage_dice_sides) && participant.npc_with_custom_dice?
                     participant.npc_damage_dice_sides.to_i
                   else
                     8
                   end

      {
        'id' => weapon.id,
        'name' => weapon.respond_to?(:name) ? (weapon.name || 'Unknown') : 'Unknown',
        'dice_count' => dice_count,
        'dice_sides' => dice_sides,
        'damage_type' => 'Physical',
        'reach' => (pattern&.melee_reach_value || GameConfig::Mechanics::REACH[:unarmed_reach]).to_i,
        'speed' => (pattern&.attack_speed || 5).to_i,
        'is_ranged' => pattern&.is_ranged || false,
        'range_hexes' => pattern&.is_ranged ? (pattern.range_in_hexes || 5).to_i : nil,
        # Ruby melee AI uses `pattern.range_in_hexes || 1` as the attack range
        # (combat_ai_service.rb:576). `reach` above only affects segment
        # compression. For ranged weapons this mirrors `range_hexes`.
        'attack_range_hexes' => ((pattern&.range_in_hexes) || 1).to_i
      }
    end

    def default_unarmed_weapon(participant)
      dice_count = if participant.respond_to?(:npc_damage_dice_count) && participant.npc_with_custom_dice?
                     participant.npc_damage_dice_count.to_i
                   else
                     2
                   end
      dice_sides = if participant.respond_to?(:npc_damage_dice_sides) && participant.npc_with_custom_dice?
                     participant.npc_damage_dice_sides.to_i
                   else
                     8
                   end
      {
        'id' => 0,
        'name' => 'Unarmed',
        'dice_count' => dice_count,
        'dice_sides' => dice_sides,
        'damage_type' => 'Physical',
        'reach' => (GameConfig::Mechanics::REACH[:unarmed_reach] || 2).to_i,
        'speed' => 5,
        'is_ranged' => false,
        'range_hexes' => nil,
        # Unarmed melee attack range is 1 hex (adjacent only).
        'attack_range_hexes' => 1,
        # Ruby returns weapon_type: :unarmed (not :melee) when no real weapon is
        # equipped; Rust honors this flag so rules gated on 'melee' skip unarmed.
        'is_unarmed' => true
      }
    end

    # ── Natural Attacks ──────────────────────────────────────────

    def serialize_natural_attacks(p)
      return [] unless p.is_npc

      archetype = p.npc_archetype
      return [] unless archetype

      attacks = archetype.respond_to?(:parsed_npc_attacks) ? archetype.parsed_npc_attacks : []
      attacks.map do |attack|
        {
          'name' => attack.name,
          'dice_count' => attack.dice_count.to_i,
          'dice_sides' => attack.dice_sides.to_i,
          'damage_type' => damage_type_string(attack.damage_type),
          'reach' => (attack.melee_reach || 2).to_i,
          'is_ranged' => attack.attack_type == 'ranged',
          'range_hexes' => attack.attack_type == 'ranged' ? (attack.range_hexes || 5).to_i : nil
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing natural attacks: #{e.message}"
      []
    end

    # ── Abilities ────────────────────────────────────────────────

    def serialize_abilities(p)
      base = p.respond_to?(:all_combat_abilities) ? p.all_combat_abilities.to_a : []
      # Ruby's scheduler (combat_resolution_service.rb:866) resolves
      # `selected_ability || find_ability_by_choice(ability_choice)` without
      # checking the character's learned catalog. Mirror that contract here so
      # Rust can resolve the same ability by id — otherwise Rust's find-by-id
      # lookup early-returns and silently drops the action.
      extras = []
      extras << p.selected_ability if p.respond_to?(:selected_ability) && p.selected_ability
      extras << p.tactical_ability if p.respond_to?(:tactical_ability) && p.tactical_ability
      if p.respond_to?(:ability_choice) && p.ability_choice && !p.ability_choice.to_s.strip.empty? &&
         (!p.respond_to?(:ability_id) || p.ability_id.nil? || p.ability_id == 0)
        resolved = resolve_ability_choice(p)
        extras << resolved if resolved
      end
      abilities = (base + extras).uniq { |a| a.id }
      # For NPCs, archetype defines per-ability use_chance. PCs always use 100.
      chance_by_id = build_ability_chance_map(p)

      abilities.map do |ability|
        {
          'id' => ability.id,
          'name' => ability.name,
          'base_damage_dice' => ability.base_damage_dice,
          'damage_modifier' => (ability.damage_modifier || 0).to_i,
          'damage_multiplier' => safe_ability_field(ability, :damage_multiplier, 1.0).to_f,
          'damage_type' => damage_type_string(ability.damage_type),
          'damage_stat' => safe_ability_field(ability, :damage_stat, nil),
          'target_type' => target_type_string(ability.target_type, ability),
          'aoe_shape' => aoe_shape_string(ability.aoe_shape),
          'aoe_radius' => ability.aoe_radius,
          'aoe_length' => ability.respond_to?(:aoe_length) ? ability.aoe_length : nil,
          'aoe_angle' => nil,
          'range_hexes' => ability.range_in_hexes.to_i,
          'cooldown_rounds' => ability.specific_cooldown_rounds.to_i,
          # qi_cost is stored in the `costs` JSONB under 'qi_cost'; the raw
          # `mana_cost` column is legacy/unused. health_cost is also stored in
          # JSONB (the schema column is unused).
          'qi_cost' => ability.parsed_costs['qi_cost'].to_i,
          'health_cost' => ability.parsed_costs['health_cost'].to_i,
          'is_healing' => ability.damage_type == 'healing',
          'lifesteal_max' => safe_ability_field(ability, :lifesteal_max, nil),
          'status_effects' => serialize_ability_status_effects(ability),
          'has_chain' => safe_ability_field(ability, :has_chain, false),
          'chain_max_targets' => safe_ability_field(ability, :chain_max_targets, 1).to_i,
          'chain_range' => safe_ability_field(ability, :chain_range, 0).to_i,
          'chain_damage_falloff' => safe_ability_field(ability, :chain_damage_falloff, 1.0).to_f,
          'execute_threshold' => safe_ability_field(ability, :execute_threshold, nil)&.to_f,
          'has_forced_movement' => !safe_ability_field(ability, :forced_movement_direction, nil).nil?,
          'bypasses_resistances' => safe_ability_field(ability, :bypasses_resistances, false),
          'use_chance' => (chance_by_id[ability.id] || 100).to_i,
          'aoe_hits_allies' => safe_ability_field(ability, :aoe_hits_allies, false),
          'applies_prone' => safe_ability_field(ability, :applies_prone, false),
          'apply_timing_coefficient' => safe_ability_field(ability, :apply_timing_coefficient, false),
          'activation_segment' => safe_ability_field(ability, :activation_segment, nil)&.to_i,
          'global_cooldown_rounds' => safe_ability_field(ability, :global_cooldown_rounds, 0).to_i,
          'chain_friendly_fire' => (ability.respond_to?(:parsed_chain_config) ? (ability.parsed_chain_config&.dig('friendly_fire') || false) : false),
          'forced_movement' => serialize_forced_movement(ability),
          'execute_effect' => serialize_execute_effect(ability),
          'conditional_damage' => serialize_conditional_damage(ability),
          'combo_condition' => serialize_combo_condition(ability),
          'damage_types' => serialize_damage_splits(ability),
          'status_duration_scaling' => safe_ability_field(ability, :status_duration_scaling, nil)
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing abilities: #{e.message}"
      []
    end

    # Map ability_id => use_chance (0-100).
    # NPCs: pull from archetype.combat_abilities_with_chances.
    # PCs/idle: empty map (callers default to 100).
    def build_ability_chance_map(p)
      return {} unless p.respond_to?(:is_npc) && p.is_npc
      archetype = p.respond_to?(:npc_archetype) ? p.npc_archetype : nil
      return {} unless archetype && archetype.respond_to?(:combat_abilities_with_chances)

      archetype.combat_abilities_with_chances.each_with_object({}) do |entry, h|
        ability = entry[:ability]
        next unless ability
        h[ability.id] = entry[:chance].to_i
      end
    rescue StandardError
      {}
    end

    def safe_ability_field(ability, field, default)
      ability.respond_to?(field) ? (ability.send(field) || default) : default
    rescue StandardError
      default
    end

    # Legacy ability_choice path (string name). Mirrors
    # combat_resolution_service.rb#find_ability_by_choice — scoped to the
    # fight's universe, case-insensitive, with underscore→space fallback.
    def resolve_ability_choice(p)
      return nil unless p.respond_to?(:ability_choice)
      choice = p.ability_choice.to_s.strip
      return nil if choice.empty?

      universe = @fight.room&.location&.zone&.world&.universe
      return nil unless universe

      candidates = [choice, choice.tr('_', ' ')].uniq
      candidates.each do |candidate|
        match = Ability.where(universe_id: [universe.id, nil])
                       .where(Sequel.ilike(:name, candidate))
                       .first
        return match if match
      end
      nil
    rescue StandardError => e
      warn "[FightStateSerializer] resolve_ability_choice failed: #{e.message}"
      nil
    end

    def serialize_forced_movement(ability)
      fm = ability.respond_to?(:parsed_forced_movement) ? ability.parsed_forced_movement : nil
      return nil unless fm
      { 'direction' => fm['direction'] || 'Away', 'distance' => (fm['distance'] || 1).to_i }
    rescue StandardError
      nil
    end

    def serialize_execute_effect(ability)
      ee = ability.respond_to?(:parsed_execute_effect) ? ability.parsed_execute_effect : nil
      return nil unless ee
      { 'instant_kill' => ee['instant_kill'] || false,
        'damage_multiplier' => ee['damage_multiplier']&.to_f }
    rescue StandardError
      nil
    end

    def serialize_conditional_damage(ability)
      conds = ability.respond_to?(:parsed_conditional_damage) ? ability.parsed_conditional_damage : nil
      return [] unless conds.is_a?(Array)
      conds.map do |c|
        { 'condition' => c['condition'] || '',
          'bonus_dice' => c['bonus_dice'],
          'bonus_damage' => c['bonus_damage']&.to_i,
          'status' => c['status'] }
      end
    rescue StandardError
      []
    end

    def serialize_combo_condition(ability)
      cc = ability.respond_to?(:parsed_combo_condition) ? ability.parsed_combo_condition : nil
      return nil unless cc
      { 'requires_status' => cc['requires_status'] || '',
        'bonus_dice' => cc['bonus_dice'],
        'consumes_status' => cc['consumes_status'] || false }
    rescue StandardError
      nil
    end

    def serialize_damage_splits(ability)
      splits = ability.respond_to?(:parsed_damage_types) ? ability.parsed_damage_types : nil
      return [] unless splits.is_a?(Array)
      splits.map { |s| { 'damage_type' => damage_type_string(s['type']), 'percent' => (s['percent'] || 0).to_f } }
    rescue StandardError
      []
    end

    def serialize_ability_status_effects(ability)
      return [] unless ability.respond_to?(:parsed_status_effects)

      effects = ability.parsed_status_effects
      return [] if effects.nil? || effects.empty?

      effects.map do |effect|
        effect_name = effect['name'] || effect['type'] || 'unknown'
        se = StatusEffect.first(name: effect_name) rescue nil
        mechanics = se&.parsed_mechanics || {}
        {
          'effect_name' => effect_name,
          'duration_rounds' => (effect['duration'] || 1).to_i,
          'chance' => (effect['chance'] || 100).to_f / 100.0,
          'value' => (effect['value'] || 0).to_i,
          'damage_mult' => effect['damage_mult']&.to_f || mechanics['multiplier']&.to_f,
          'threshold' => effect['threshold']&.to_i,
          'effect_type' => se ? effect_type_string(se.effect_type) : 'Buff',
          'flat_reduction' => (mechanics['flat_reduction'] || 0).to_i,
          'flat_protection' => (mechanics['flat_protection'] || 0).to_i,
          'shield_hp' => (mechanics['shield_hp'] || 0).to_i,
          'dot_damage' => mechanics['damage'],
          'dot_damage_type' => mechanics['damage_type'] ? damage_type_string(mechanics['damage_type']) : nil,
          'damage_types' => extract_damage_types(se&.effect_type, mechanics),
          'stack_behavior' => stack_behavior_string(se&.stacking_behavior || 'refresh'),
          'max_stacks' => (se&.max_stacks || 1).to_i
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing ability status effects: #{e.message}"
      []
    end

    # ── Cooldowns ────────────────────────────────────────────────

    def serialize_cooldowns(p)
      return {} unless p.respond_to?(:parsed_ability_cooldowns)

      cooldowns = p.parsed_ability_cooldowns
      return {} unless cooldowns.is_a?(Hash)

      abilities = p.respond_to?(:all_combat_abilities) ? p.all_combat_abilities : []
      ability_map = abilities.each_with_object({}) { |a, h| h[a.name] = a.id }

      result = {}
      cooldowns.each do |name, rounds|
        ability_id = ability_map[name] || name.to_i
        result[ability_id] = rounds.to_i if ability_id > 0
      end
      result
    rescue StandardError
      {}
    end

    # ── Status Effects ───────────────────────────────────────────

    def serialize_status_effects(p)
      effects = p.respond_to?(:active_status_effects) ? p.active_status_effects : []

      effects.map do |pse|
        se = pse.respond_to?(:status_effect) ? pse.status_effect : nil
        mechanics = se&.parsed_mechanics || {}
        {
          'effect_name' => se&.name || 'unknown',
          'effect_type' => effect_type_string(se&.effect_type || 'buff'),
          'remaining_rounds' => (pse.respond_to?(:rounds_remaining) ? pse.rounds_remaining : 1).to_i,
          'stack_count' => (pse.respond_to?(:stack_count) ? (pse.stack_count || 1) : 1).to_i,
          'max_stacks' => (se&.respond_to?(:max_stacks) ? (se.max_stacks || 1) : 1).to_i,
          'stack_behavior' => stack_behavior_string(se&.stacking_behavior || 'refresh'),
          'flat_reduction' => (mechanics['flat_reduction'] || 0).to_i,
          'flat_protection' => (mechanics['flat_protection'] || 0).to_i,
          'damage_types' => extract_damage_types(se&.effect_type, mechanics),
          'dot_damage' => mechanics['damage'],
          'dot_damage_type' => mechanics['damage_type'] ? damage_type_string(mechanics['damage_type']) : nil,
          'shield_hp' => se&.effect_type == 'shield' ? (pse.respond_to?(:effect_value) ? (pse.effect_value || 0) : 0).to_i : 0,
          # Fear's attack_penalty lives in mechanics, not effective_modifier. Surface
          # it via the shared `value` field so Rust's fear_attack_penalty helper reads it.
          # Healing-modifier's multiplier (e.g., 1.5 for +50%) converts to a Rust
          # integer percent delta — Rust healing_scalar does `1.0 + value/100`.
          'value' => if se&.effect_type == 'fear'
                       (mechanics['attack_penalty'] || -2).to_i
                     elsif se&.effect_type == 'healing'
                       mult = (mechanics['multiplier'] || 1.0).to_f
                       ((mult - 1.0) * 100).round
                     elsif se&.effect_type == 'healing_tick'
                       # Regeneration rate per round. Rust process_healing reads
                       # effect.value as i32 rate. Ruby keeps fractional rate in
                       # mechanics['healing'] (e.g., 0.5); truncation here means
                       # sub-1.0 rates won't heal in Rust. Scenarios needing exact
                       # parity should use integer rates.
                       (mechanics['healing'] || 0).to_i
                     else
                       (pse.respond_to?(:effective_modifier) ? pse.effective_modifier : 0).to_i
                     end,
          'damage_mult' => mechanics['multiplier']&.to_f,
          # source_id for taunt/fear/grapple mechanics so Rust can redirect targeting
          # and compute penalties relative to the causing participant.
          'source_id' => (pse.respond_to?(:source_participant_id) ? pse.source_participant_id : nil),
          # cannot_target_id for targeting_restriction effects (e.g. sanctuary).
          # Ruby status_effect_service.rb#cannot_target_ids rejects attacks on
          # this id; Rust mirrors that check in resolve_attack_target.
          'cannot_target_id' => (mechanics['cannot_target_id'] && mechanics['cannot_target_id'].to_i != 0 ? mechanics['cannot_target_id'].to_i : nil)
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing status effects: #{e.message}"
      []
    end

    # ── Monsters ─────────────────────────────────────────────────

    def serialize_monsters
      return [] unless @fight.respond_to?(:large_monster_instances_dataset)

      @fight.large_monster_instances_dataset.all.select { |m| m.status != 'defeated' }.map do |monster|
        template = monster.monster_template
        {
          'id' => monster.id,
          'name' => template&.name || 'Unknown',
          'current_hp' => monster.current_hp.to_i,
          'max_hp' => monster.max_hp.to_i,
          'center' => { 'x' => monster.center_hex_x.to_i, 'y' => monster.center_hex_y.to_i, 'z' => 0 },
          'segments' => serialize_monster_segments(monster),
          'shake_off_threshold' => (template&.shake_off_threshold || 2).to_i,
          'climb_distance' => (template&.climb_distance || 10).to_i,
          'facing' => (monster.facing_direction || 0).to_i,
          'status' => monster_status_string(monster.status),
          'hex_width' => (template&.hex_width || 1).to_i,
          'hex_height' => (template&.hex_height || 1).to_i,
          'defeat_threshold_percent' => (template&.defeat_threshold_percent || 0).to_i,
          'mount_states' => serialize_mount_states(monster)
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing monsters: #{e.message}"
      []
    end

    def serialize_monster_segments(monster)
      monster.monster_segment_instances_dataset.all.map do |seg|
        tmpl = seg.monster_segment_template
        read = ->(attr, default) { tmpl.respond_to?(attr) ? (tmpl.send(attr) || default) : default }
        {
          'id' => seg.id,
          'name' => read.call(:name, 'Unknown'),
          'current_hp' => seg.current_hp.to_i,
          'max_hp' => seg.max_hp.to_i,
          'attacks_per_round' => read.call(:attacks_per_round, 0).to_i,
          'dice_count' => read.call(:dice_count, 2).to_i,
          'dice_sides' => read.call(:dice_sides, 8).to_i,
          'damage_bonus' => read.call(:damage_bonus, 0).to_i,
          'damage_type' => damage_type_string(read.call(:damage_type, 'physical')),
          'reach' => read.call(:reach, 1).to_i,
          'is_weak_point' => read.call(:is_weak_point, false),
          'required_for_mobility' => read.call(:required_for_mobility, false),
          'position' => {
            'x' => (monster.center_hex_x.to_i + read.call(:hex_offset_x, 0).to_i),
            'y' => (monster.center_hex_y.to_i + read.call(:hex_offset_y, 0).to_i),
            'z' => 0
          },
          'status' => segment_status_string(seg.status),
          'attacks_remaining' => (seg.attacks_remaining_this_round || read.call(:attacks_per_round, 0)).to_i,
          'damage_dice' => read.call(:damage_dice, nil),
          'hex_offset_x' => read.call(:hex_offset_x, 0).to_i,
          'hex_offset_y' => read.call(:hex_offset_y, 0).to_i
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing monster segments: #{e.message}"
      []
    end

    def serialize_mount_states(monster)
      return [] unless monster.respond_to?(:monster_mount_states)

      monster.monster_mount_states.map do |ms|
        {
          'participant_id' => ms.fight_participant_id.to_i,
          'monster_id' => monster.id,
          'segment_id' => (ms.current_segment_id || 0).to_i,
          'mount_status' => mount_status_string(ms.mount_status),
          'climb_progress' => (ms.climb_progress || 0).to_i,
          'is_at_weak_point' => ms.respond_to?(:at_weak_point?) ? ms.at_weak_point? : false
        }
      end
    rescue StandardError
      []
    end

    # ── Hex Map ──────────────────────────────────────────────────

    def serialize_hex_map
      room = @fight.room
      hex_map = {
        'width' => (@fight.arena_width || 10).to_i,
        'height' => (@fight.arena_height || 10).to_i,
        'cells' => {}
      }

      if room&.has_battle_map
        room.room_hexes.each do |hex|
          key = [hex.hex_x.to_i, hex.hex_y.to_i]
          hex_map['cells'][key] = {
            'x' => hex.hex_x.to_i,
            'y' => hex.hex_y.to_i,
            'elevation_level' => (hex.respond_to?(:elevation_level) ? (hex.elevation_level || 0) : 0).to_i,
            'blocks_movement' => hex.respond_to?(:blocks_movement) ? (hex.blocks_movement || false) : false,
            'blocks_los' => hex.respond_to?(:blocks_line_of_sight) ? (hex.blocks_line_of_sight || false) : false,
            'is_difficult_terrain' => hex.respond_to?(:is_difficult_terrain) ? (hex.is_difficult_terrain || false) : false,
            'cover_type' => cover_type_string(hex),
            'hazard_type' => hazard_type_string(hex.respond_to?(:hazard_type) ? hex.hazard_type : nil),
            'hazard_damage' => (hex.respond_to?(:hazard_damage_per_round) ? (hex.hazard_damage_per_round || 0) : 0).to_i,
            'is_ramp' => hex.respond_to?(:is_ramp) ? (hex.is_ramp || false) : false,
            'is_stairs' => hex.respond_to?(:is_stairs) ? (hex.is_stairs || false) : false,
            'is_ladder' => hex.respond_to?(:is_ladder) ? (hex.is_ladder || false) : false,
            'is_concealment' => hex.respond_to?(:hex_type) && hex.hex_type == 'concealed',
            'passable_edges' => serialize_passable_edges(hex),
            'cover_height' => (hex.respond_to?(:cover_height) ? (hex.cover_height || 0) : 0).to_i,
            'water_type' => water_type_string(hex.respond_to?(:water_type) ? hex.water_type : nil),
            'hit_points' => hex.respond_to?(:hit_points) ? hex.hit_points : nil,
            'wall_feature' => wall_feature_string(hex.respond_to?(:wall_feature) ? hex.wall_feature : nil),
            'door_open' => false,
            'window_broken' => false,
            'traversable' => hex.respond_to?(:traversable) ? (hex.traversable != false) : true,
            'hex_kind' => hex_kind_string(hex.respond_to?(:hex_type) ? hex.hex_type : nil)
          }
        end
      end

      hex_map
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing hex map: #{e.message}"
      { 'width' => 10, 'height' => 10, 'cells' => {} }
    end

    # ── Observer Effects ─────────────────────────────────────────

    def serialize_observer_effects
      instance_id = @fight.respond_to?(:activity_instance_id) ? @fight.activity_instance_id : nil
      return [] unless instance_id

      activity = ActivityInstance[instance_id]
      return [] unless activity

      effects = ObserverEffectService.effects_for_combat(activity)
      result = []

      effects.each do |participant_id, participant_effects|
        participant_effects.each do |effect_type, value|
          case effect_type.to_s
          when 'forced_target'
            result << build_observer_effect('forced_target', 0, participant_id.to_i, value.to_i, 1.0, 0)
          when 'halve_damage_from'
            Array(value).each do |source_id|
              result << build_observer_effect('halve_damage_from', source_id.to_i, participant_id.to_i, 0, 0.5, 0)
            end
          when 'damage_dealt_mult'
            result << build_observer_effect('damage_dealt_mult', participant_id.to_i, participant_id.to_i, 0, value.to_f, 0)
          when 'damage_taken_mult'
            result << build_observer_effect('damage_taken_mult', 0, participant_id.to_i, 0, value.to_f, 0)
          else
            result << build_observer_effect(
              effect_type.to_s, 0, participant_id.to_i, 0,
              value.is_a?(Numeric) ? value.to_f : 1.0,
              value.is_a?(Integer) ? value : 0
            )
          end
        end
      end

      result
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing observer effects: #{e.message}"
      []
    end

    def build_observer_effect(type, source_id, target_id, forced_target_id, multiplier, value)
      {
        'effect_type' => type,
        'source_id' => source_id,
        'target_id' => target_id,
        'forced_target_id' => forced_target_id,
        'multiplier' => multiplier,
        'value' => value
      }
    end

    # ── Player Actions ───────────────────────────────────────────

    def serialize_action(p)
      {
        'participant_id' => p.id,
        'movement' => serialize_movement_action(p),
        'main_action' => serialize_main_action(p),
        'tactic' => serialize_tactic(p),
        'qi_attack' => (p.willpower_attack || 0).to_i,
        'qi_defense' => (p.willpower_defense || 0).to_i,
        'qi_ability' => (p.willpower_ability || 0).to_i,
        'qi_movement' => (p.willpower_movement || 0).to_i
      }
    end

    def serialize_movement_action(p)
      case p.movement_action
      when 'towards_person'
        { 'TowardsPerson' => (p.movement_target_participant_id || p.target_participant_id || 0).to_i }
      when 'away_from'
        { 'AwayFrom' => (p.movement_target_participant_id || p.target_participant_id || 0).to_i }
      when 'maintain_distance'
        { 'MaintainDistance' => {
          'target_id' => (p.movement_target_participant_id || 0).to_i,
          'range' => (p.maintain_distance_range || 3).to_i
        } }
      when 'move_to_hex'
        { 'MoveToHex' => {
          'x' => (p.target_hex_x || 0).to_i,
          'y' => (p.target_hex_y || 0).to_i,
          'z' => 0
        } }
      when 'flee'
        # Room cardinal directions: 'north'/'south'/'east'/'west'/'up'/'down'.
        # Rust carries them as-is for end-of-round room transition via RoomAdjacencyService.
        flee_dir = p.respond_to?(:flee_direction) ? (p.flee_direction || 'south') : 'south'
        exit_id = p.respond_to?(:flee_exit_id) ? p.flee_exit_id : nil
        { 'Flee' => { 'direction' => flee_dir.to_s.downcase, 'exit_id' => exit_id } }
      when 'mount_monster'
        { 'Mount' => { 'monster_id' => (p.respond_to?(:targeting_monster_id) ? (p.targeting_monster_id || 0) : 0).to_i } }
      when 'climb'
        'Climb'
      when 'cling'
        'Cling'
      when 'dismount'
        'Dismount'
      when 'wall_flip'
        { 'WallFlip' => {
            'wall_x' => p.target_hex_x&.to_i,
            'wall_y' => p.target_hex_y&.to_i
          } }
      else
        'StandStill'
      end
    end

    def serialize_main_action(p)
      case p.main_action
      when 'attack'
        mon_id = p.respond_to?(:targeting_monster_id) ? p.targeting_monster_id : nil
        seg_id = p.respond_to?(:targeting_segment_id) ? p.targeting_segment_id : nil
        { 'Attack' => {
            'target_id' => (p.target_participant_id || 0).to_i,
            'monster_id' => mon_id&.to_i,
            'segment_id' => seg_id&.to_i
          } }
      when 'defend'
        'Defend'
      when 'ability'
        # Ability target falls back from ability_target_participant_id to
        # target_participant_id (matching combat_resolution_service.rb:861-868).
        target = p.ability_target_participant_id || p.target_participant_id
        ability_id = p.ability_id
        # Legacy ability_choice path: when no ability_id is set, resolve the
        # name to an id so Rust's dispatcher can look it up by id in the
        # catalog we widened in serialize_abilities.
        if (ability_id.nil? || ability_id == 0) && p.respond_to?(:ability_choice) && p.ability_choice
          resolved = resolve_ability_choice(p)
          ability_id = resolved.id if resolved
        end
        { 'Ability' => { 'ability_id' => (ability_id || 0).to_i, 'target_id' => target } }
      when 'dodge'
        'Dodge'
      when 'sprint'
        'Sprint'
      when 'surrender'
        'Surrender'
      when 'stand'
        'StandUp'
      else
        'Pass'
      end
    end

    # ── Interactive objects + FightHex overlays ──────────────────

    def serialize_interactive_objects
      return [] unless defined?(BattleMapElement)

      BattleMapElement.where(fight_id: @fight.id).all.map do |el|
        {
          'id' => el.id,
          'element_type' => element_type_string(el.element_type),
          'state' => element_state_string(el.state),
          'hex_x' => (el.hex_x || 0).to_i,
          'hex_y' => (el.hex_y || 0).to_i,
          'edge_side' => el.edge_side
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing interactive_objects: #{e.message}"
      []
    end

    # Subset of StatusEffect rows Rust needs to apply by name (on-hex-entry
    # triggers for toxic_mushrooms/lotus_pollen, plus 'wet' so Rust can detect
    # the +2 duration bonus without a DB lookup). Ruby fight_hex_effect_service
    # applies these by name via StatusEffectService.
    # 'dangling' + 'oil_slicked' are applied by Rust's interactive_objects
    # on long-fall and prone-in-oil hex entries; omitting them made
    # apply_status_by_name silently no-op in Rust mode.
    STATUS_TEMPLATES_ALLOWLIST = %w[poisoned intoxicated wet on_fire dangling oil_slicked].freeze

    def serialize_status_effect_templates
      return [] unless defined?(StatusEffect)

      StatusEffect.where(name: STATUS_TEMPLATES_ALLOWLIST).all.map do |se|
        mech = se.respond_to?(:parsed_mechanics) ? se.parsed_mechanics : (se.mechanics || {})
        # Defaults mirror Ruby's per-effect duration_rounds at apply sites
        # (fight_hex_effect_service.rb): oil_slicked persists (99), dangling
        # clears after climb-back (1), on_fire is long-lived (99).
        default_duration = case se.name
                           when 'poisoned', 'intoxicated' then 2
                           when 'wet' then 5
                           when 'on_fire', 'oil_slicked' then 99
                           when 'dangling' then 1
                           else 1
                           end
        {
          'effect_name' => se.name,
          'effect_type' => effect_type_string(se.effect_type),
          'default_duration_rounds' => default_duration,
          'stack_behavior' => stack_behavior_string(se.stacking_behavior),
          'max_stacks' => (se.max_stacks || 1).to_i,
          'value' => (mech['damage'].to_i if se.effect_type == 'damage_tick') || 0,
          'dot_damage' => se.effect_type == 'damage_tick' ? mech['damage'].to_s : nil,
          'dot_damage_type' => se.effect_type == 'damage_tick' && mech['damage_type'] ? damage_type_string(mech['damage_type']) : nil
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing status_effect_templates: #{e.message}"
      []
    end

    # Decode the room's wall-mask PNG into a packed byte buffer + hex geometry.
    # Rust consumes this to run pixel-level LoS ray-casts (matching
    # WallMaskService#ray_los_clear?). Returns nil when the room has no mask.
    #
    # Packed encoding: one byte per pixel:
    #   0 = floor, 1 = wall, 2 = door, 3 = window
    # Emitted as base64 over JSON (Rust deserializer decodes via custom serde).
    #
    # Result is cached class-wide, keyed by the room's wall-mask URL — masks
    # don't change during a fight, and pixel decode is O(W*H) with a per-call
    # Vips getpoint that's too slow to repeat every round.
    @@wall_mask_cache = {}

    def serialize_wall_mask
      room = @fight.room
      return nil unless room && room.respond_to?(:battle_map_wall_mask_url)
      url = room.battle_map_wall_mask_url.to_s.strip
      return nil if url.empty?

      cached = @@wall_mask_cache[url]
      return cached if cached

      service = WallMaskService.for_room(room)
      return nil unless service

      service.send(:load_image)
      image = service.instance_variable_get(:@image)
      return nil unless image

      width = image.width.to_i
      height = image.height.to_i
      return nil if width <= 0 || height <= 0

      pixels = pack_wall_mask_pixels(image, width, height)
      geometry = service.send(:hex_geometry)

      payload = {
        'width' => width,
        'height' => height,
        'pixels' => pixels,
        'hex_geometry' => {
          'hex_size' => geometry[:hex_size].to_f,
          'hex_height' => geometry[:hex_height].to_f,
          'min_x' => geometry[:min_x].to_i,
          'min_y' => geometry[:min_y].to_i,
          'num_visual_rows' => geometry[:num_visual_rows].to_i
        }
      }
      @@wall_mask_cache[url] = payload
      payload
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing wall_mask: #{e.message}"
      nil
    end

    # Bulk-read the image into a contiguous RGB byte buffer (one Vips call),
    # then classify every pixel in pure Ruby — much faster than per-pixel
    # getpoint for large masks.
    def pack_wall_mask_pixels(image, width, height)
      rgb = image.bands >= 3 ? image.extract_band(0, n: 3) : image
      raw = rgb.write_to_memory
      bytes = raw.bytes
      # Vips stores as row-major [r,g,b, r,g,b, ...] by default; the layout
      # depends on interpretation. write_to_memory returns bands interleaved
      # for most formats. Assume RGB interleaved.
      buf = String.new(capacity: width * height, encoding: Encoding::BINARY)
      stride = 3
      pixel_count = width * height
      i = 0
      while i < pixel_count
        base = i * stride
        r = bytes[base].to_i
        g = bytes[base + 1].to_i
        b = bytes[base + 2].to_i
        code =
          if r > 128 && g < 64 && b < 64
            1 # wall
          elsif g > 128 && r < 64 && b < 64
            2 # door
          elsif b > 128 && r < 64 && g < 64
            3 # window
          else
            0 # floor
          end
        buf << code.chr
        i += 1
      end
      [buf].pack('m0')
    end

    # RoomHex positions with hex_type='window' for the window-break tactic.
    # Rust's FightState.window_positions uses these to validate break targets.
    def serialize_window_positions
      return [] unless defined?(RoomHex) && @fight.room_id

      RoomHex.where(room_id: @fight.room_id, hex_type: 'window').all.map do |rh|
        [rh.hex_x.to_i, rh.hex_y.to_i]
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing window_positions: #{e.message}"
      []
    end

    def serialize_fight_hexes
      return [] unless defined?(FightHex)

      FightHex.where(fight_id: @fight.id).all.map do |fh|
        {
          'id' => fh.id,
          'hex_x' => fh.hex_x.to_i,
          'hex_y' => fh.hex_y.to_i,
          'hex_type' => fight_hex_type_string(fh.hex_type),
          'hazard_type' => fh.respond_to?(:hazard_type) && fh.hazard_type ? hazard_type_string(fh.hazard_type) : nil,
          'hazard_damage_per_round' => (fh.respond_to?(:hazard_damage_per_round) ? (fh.hazard_damage_per_round || 0) : 0).to_i
        }
      end
    rescue StandardError => e
      warn "[FightStateSerializer] Error serializing fight_hexes: #{e.message}"
      []
    end

    def element_type_string(t)
      case t.to_s
      when 'water_barrel' then 'WaterBarrel'
      when 'oil_barrel' then 'OilBarrel'
      when 'munitions_crate' then 'MunitionsCrate'
      when 'toxic_mushrooms' then 'ToxicMushrooms'
      when 'lotus_pollen' then 'LotusPollen'
      when 'vase' then 'Vase'
      when 'cliff_edge' then 'CliffEdge'
      else 'Vase'
      end
    end

    def element_state_string(s)
      case s.to_s
      when 'intact' then 'Intact'
      when 'broken' then 'Broken'
      when 'ignited' then 'Ignited'
      when 'detonated' then 'Detonated'
      else 'Intact'
      end
    end

    def fight_hex_type_string(t)
      case t.to_s
      when 'oil' then 'Oil'
      when 'sharp_ground' then 'SharpGround'
      when 'fire' then 'Fire'
      when 'puddle' then 'Puddle'
      when 'long_fall' then 'LongFall'
      when 'open_window' then 'OpenWindow'
      else 'Oil'
      end
    end

    def serialize_tactic(p)
      case p.tactic_choice
      when 'area_denial'
        'AreaDenial'
      when 'qi_aura'
        'QiAura'
      when 'qi_lightness'
        mode = case p.qi_lightness_mode
               when 'wall_bounce' then 'WallBounce'
               when 'tree_leap' then 'TreeLeap'
               else 'WallRun'
               end
        { 'QiLightness' => { 'mode' => mode } }
      when 'guard'
        { 'Guard' => { 'ally_id' => (p.tactic_target_participant_id || 0).to_i } }
      when 'back_to_back'
        { 'BackToBack' => { 'ally_id' => (p.tactic_target_participant_id || 0).to_i } }
      when 'tactical_ability'
        { 'TacticalAbility' => {
          'ability_id' => (p.respond_to?(:tactical_ability_id) ? (p.tactical_ability_id || 0) : 0).to_i,
          'target_id' => p.respond_to?(:tactic_target_participant_id) ? p.tactic_target_participant_id : nil
        } }
      when 'break'
        eid = p.respond_to?(:tactic_target_element_id) ? p.tactic_target_element_id : nil
        if eid
          { 'Break' => { 'element_id' => eid.to_i, 'target_x' => nil, 'target_y' => nil } }
        else
          hex_x, hex_y = tactic_target_hex_for(p)
          { 'Break' => { 'element_id' => nil, 'target_x' => hex_x, 'target_y' => hex_y } }
        end
      when 'detonate'
        { 'Detonate' => { 'element_id' => tactic_target_element_id_for(p) } }
      when 'ignite'
        hex_x, hex_y = tactic_target_hex_for(p)
        { 'Ignite' => { 'target_x' => hex_x, 'target_y' => hex_y } }
      else
        'None'
      end
    end

    # Helpers for reading tactic_target_data JSONB.
    def tactic_target_element_id_for(p)
      return 0 unless p.respond_to?(:tactic_target_element_id)

      (p.tactic_target_element_id || 0).to_i
    end

    def tactic_target_hex_for(p)
      return [0, 0] unless p.respond_to?(:tactic_target_hex)

      hex = p.tactic_target_hex || [0, 0]
      [hex[0].to_i, hex[1].to_i]
    end

    # ── Enum Mappers ─────────────────────────────────────────────

    def damage_type_string(type)
      case type.to_s.downcase
      when 'fire' then 'Fire'
      when 'ice', 'frost', 'cold' then 'Ice'
      when 'lightning', 'electric' then 'Lightning'
      when 'poison' then 'Poison'
      when 'psychic', 'mental' then 'Psychic'
      when 'holy', 'light', 'divine' then 'Holy'
      when 'dark', 'shadow', 'necrotic' then 'Dark'
      when 'wind', 'air' then 'Wind'
      when 'earth' then 'Earth'
      when 'water' then 'Water'
      else 'Physical'
      end
    end

    def target_type_string(type, ability = nil)
      case type.to_s.downcase
      when 'self' then 'Self'
      when 'ally', 'all_allies' then 'Ally'
      else
        if ability && ability.respond_to?(:aoe_shape) && ability.aoe_shape &&
           !ability.aoe_shape.to_s.empty? && ability.aoe_shape.to_s.downcase != 'single'
          aoe_shape_string(ability.aoe_shape) || 'Single'
        else
          'Single'
        end
      end
    end

    def aoe_shape_string(shape)
      case shape.to_s.downcase
      when 'circle' then 'Circle'
      when 'cone' then 'Cone'
      when 'line' then 'Line'
      else nil
      end
    end

    def effect_type_string(type)
      case type.to_s
      when 'DamageReduction', 'damage_reduction' then 'DamageReduction'
      when 'Protection', 'protection' then 'Protection'
      when 'Shield', 'shield' then 'Shield'
      when 'DamageOverTime', 'dot', 'damage_tick' then 'DamageOverTime'
      when 'CrowdControl', 'cc', 'stun' then 'CrowdControl'
      when 'Vulnerability', 'vulnerability' then 'Vulnerability'
      when 'Regeneration', 'regen', 'healing_tick' then 'Regeneration'
      # Preserve Ruby's semantic effect types rather than flattening to Debuff.
      when 'movement' then 'MovementBlock'
      when 'action_restriction' then 'ActionRestriction'
      when 'targeting_restriction' then 'TargetingRestriction'
      when 'fear' then 'Fear'
      when 'grapple' then 'Grapple'
      when 'healing', 'healing_modifier' then 'HealingModifier'
      when 'incoming_damage' then 'IncomingDamage'
      when 'outgoing_damage' then 'OutgoingDamage'
      when 'Debuff', 'debuff' then 'Debuff'
      else 'Buff'
      end
    end

    def stack_behavior_string(behavior)
      case behavior.to_s
      when 'stack' then 'Stack'
      when 'duration' then 'Duration'
      when 'ignore' then 'Ignore'
      else 'Refresh'
      end
    end

    def extract_damage_types(effect_type, mechanics)
      types = case effect_type.to_s
              when 'damage_reduction' then mechanics['types']
              when 'protection' then mechanics['types']
              when 'shield' then mechanics['types_absorbed']
              when 'incoming_damage' then [mechanics['damage_type']].compact
              else []
              end
      (types || []).map { |t| damage_type_string(t) }
    rescue StandardError
      []
    end

    def monster_status_string(status)
      case status.to_s
      when 'collapsed' then 'Collapsed'
      when 'defeated' then 'Defeated'
      else 'Active'
      end
    end

    def segment_status_string(status)
      case status.to_s
      when 'damaged' then 'Damaged'
      when 'broken', 'destroyed' then 'Destroyed'
      else 'Healthy'
      end
    end

    def mount_status_string(status)
      case status.to_s
      when 'climbing' then 'Climbing'
      when 'at_weak_point' then 'AtWeakPoint'
      when 'thrown' then 'Thrown'
      when 'dismounted' then 'Dismounted'
      else 'Mounted'
      end
    end

    # Ruby RoomHex.passable_edges is an integer bitfield where bit N (index from
    # EDGE_DIRECTION_BITS) = 1 means the hex is passable from that direction.
    # Bits: N=0, NE=1, SE=2, S=3, SW=4, NW=5.
    # Rust expects HashMap<Direction, bool>.
    EDGE_BIT_INDEX = { 'N' => 0, 'NE' => 1, 'SE' => 2, 'S' => 3, 'SW' => 4, 'NW' => 5 }.freeze

    def serialize_passable_edges(hex)
      bits = hex.respond_to?(:passable_edges) ? hex.passable_edges : nil
      return nil if bits.nil?

      EDGE_BIT_INDEX.each_with_object({}) do |(dir, idx), h|
        h[dir] = bits[idx] == 1
      end
    rescue StandardError
      nil
    end

    def cover_type_string(hex)
      return nil unless hex.respond_to?(:has_cover) && hex.has_cover
      return 'Destructible' if hex.respond_to?(:destroyable) && hex.destroyable

      'Half'
    end

    def hazard_type_string(type)
      case type.to_s.downcase
      when 'fire' then 'Fire'
      when 'pit' then 'Pit'
      when 'poison' then 'Poison'
      when 'spikes' then 'Spikes'
      else nil
      end
    end

    def water_type_string(type)
      case type.to_s.downcase
      when 'puddle'   then 'Puddle'
      when 'wading'   then 'Wading'
      when 'swimming' then 'Swimming'
      when 'deep'     then 'Deep'
      else nil
      end
    end

    def wall_feature_string(feature)
      case feature.to_s.downcase
      when ''              then nil
      when 'wall'          then 'Wall'
      when 'wall_corner'   then 'WallCorner'
      when 'tree'          then 'Tree'
      when 'door'          then 'Door'
      when 'window'        then 'Window'
      when 'furniture'     then 'Furniture'
      else { 'Other' => feature.to_s }
      end
    end

    # Map Ruby `RoomHex#hex_type` values to Rust `HexKind` variants.
    # Overlay hazards (oil/fire pools) live on FightHex, not here.
    def hex_kind_string(kind)
      case kind.to_s.downcase
      when '', 'normal', 'floor', 'concealed', 'safe', 'treasure',
           'difficult', 'hazard', 'trap', 'cover', 'debris' then map_basic_hex_kind(kind)
      when 'wall'     then 'Wall'
      when 'door'     then 'Door'
      when 'window'   then 'Window'
      when 'pit'      then 'Pit'
      when 'fire'     then 'Fire'
      when 'water'    then 'Water'
      when 'off_map'  then 'OffMap'
      else 'Normal'
      end
    end

    def map_basic_hex_kind(kind)
      case kind.to_s.downcase
      when 'trap'   then 'Trap'
      when 'cover'  then 'Cover'
      when 'debris' then 'Debris'
      else 'Normal'
      end
    end

    def determine_ai_profile(p)
      archetype = p.respond_to?(:npc_archetype) ? p.npc_archetype : nil
      if archetype && archetype.respond_to?(:ai_profile) && archetype.ai_profile
        archetype.ai_profile
      elsif p.is_npc
        'balanced'
      else
        # Idle/AFK PCs default to defensive — matches CombatAIService.determine_profile
        # (combat_ai_service.rb:188). Rust's ai/mod.rs falls back to "balanced" when
        # ai_profile is nil, so we must emit the right profile here.
        'defensive'
      end
    end
  end
end
