# frozen_string_literal: true

# Manages status effects on fight participants.
# Handles applying, expiring, querying, and calculating effect modifiers.
class StatusEffectService
  class << self
    # Apply a status effect to a participant
    # @param participant [FightParticipant] target participant
    # @param effect [StatusEffect] the effect to apply
    # @param duration_rounds [Integer] how many rounds the effect lasts
    # @param value [Integer, nil] optional override for effect value
    # @param applied_by [FightParticipant, nil] who applied the effect
    # @return [ParticipantStatusEffect] the created/updated effect
    def apply(participant:, effect:, duration_rounds:, value: nil, applied_by: nil)
      existing = ParticipantStatusEffect.first(
        fight_participant_id: participant.id,
        status_effect_id: effect.id
      )

      expires_at = participant.fight.round_number + duration_rounds

      case effect.stacking_behavior
      when 'refresh'
        if existing
          existing.refresh!(duration_rounds, new_value: value)
          return existing
        end
      when 'stack'
        if existing
          if existing.stack_count < (effect.max_stacks || 1)
            existing.add_stack!(new_duration: duration_rounds)
          else
            existing.refresh!(duration_rounds) # Refresh duration at max stacks
          end
          return existing
        end
      when 'duration'
        # Add durations together - stun 1 + stun 1 = stun 2
        if existing
          existing.extend_duration!(duration_rounds)
          return existing
        end
      when 'ignore'
        return existing if existing
      end

      # Create new effect
      ParticipantStatusEffect.create(
        fight_participant_id: participant.id,
        status_effect_id: effect.id,
        applied_by_participant_id: applied_by&.id,
        expires_at_round: expires_at,
        applied_at_round: participant.fight.round_number,
        applied_at_segment: nil,
        effect_value: value,
        stack_count: 1
      )
    end

    # Apply a status effect by name
    # @param participant [FightParticipant] target participant
    # @param effect_name [String] name of the effect (e.g., "snared")
    # @param duration_rounds [Integer] how many rounds the effect lasts
    # @param value [Integer, nil] optional override for effect value
    # @param applied_by [FightParticipant, nil] who applied the effect
    # @return [ParticipantStatusEffect, nil] the created effect or nil if not found
    def apply_by_name(participant:, effect_name:, duration_rounds:, value: nil, applied_by: nil)
      effect = StatusEffect.first(name: effect_name)
      return nil unless effect

      apply(
        participant: participant,
        effect: effect,
        duration_rounds: duration_rounds,
        value: value,
        applied_by: applied_by
      )
    end

    # Remove expired effects from a fight
    # @param fight [Fight] the fight to clean up
    # @return [Integer] number of effects removed
    def expire_effects(fight)
      # Get participant IDs directly from database without loading objects
      participant_ids = fight.fight_participants_dataset.select_map(:id)
      return 0 if participant_ids.empty?

      # Delete expired effects for these participants
      ParticipantStatusEffect
        .where(fight_participant_id: participant_ids)
        .where { expires_at_round <= fight.round_number }
        .delete
    end

    # Check if participant can move (snared check)
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if participant can move
    def can_move?(participant)
      !has_blocking_movement_effect?(participant)
    end

    # Check if participant has any effect that blocks movement
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if movement is blocked
    def has_blocking_movement_effect?(participant)
      active_effects(participant).any? do |pse|
        pse.status_effect&.blocks_movement?
      end
    end

    # Get the total incoming damage modifier from status effects
    # (positive = more damage taken, negative = less damage taken)
    # @param participant [FightParticipant] the participant
    # @return [Integer] total modifier to apply to each incoming attack
    def incoming_damage_modifier(participant)
      modifier = 0

      active_effects(participant).each do |pse|
        effect = pse.status_effect
        next unless effect&.effect_type == 'incoming_damage'

        # Use effect_value override if present, otherwise use effect's default
        base_mod = pse.effect_value || effect.modifier_value
        # Multiply by stacks
        modifier += base_mod * (pse.stack_count || 1)
      end

      modifier
    end

    # Get the total outgoing damage modifier from status effects
    # @param participant [FightParticipant] the participant
    # @return [Integer] total modifier to apply to each outgoing attack
    def outgoing_damage_modifier(participant)
      modifier = 0

      active_effects(participant).each do |pse|
        effect = pse.status_effect
        next unless effect&.effect_type == 'outgoing_damage'

        base_mod = pse.effect_value || effect.modifier_value
        modifier += base_mod * (pse.stack_count || 1)
      end

      modifier
    end

    # Get all active effects for a participant
    # @param participant [FightParticipant] the participant
    # @return [Array<ParticipantStatusEffect>] active effects
    def active_effects(participant)
      return [] unless participant&.fight

      ParticipantStatusEffect
        .where(fight_participant_id: participant.id)
        .where { expires_at_round > participant.fight.round_number }
        .eager(:status_effect)
        .all
    end

    # Check if participant has a specific effect
    # @param participant [FightParticipant] the participant
    # @param effect_name [String] name of the effect to check
    # @return [Boolean] true if participant has the effect
    def has_effect?(participant, effect_name)
      return false unless participant&.fight

      ParticipantStatusEffect
        .join(:status_effects, id: :status_effect_id)
        .where(Sequel[:participant_status_effects][:fight_participant_id] => participant.id)
        .where(Sequel[:status_effects][:name] => effect_name)
        .where { Sequel[:participant_status_effects][:expires_at_round] > participant.fight.round_number }
        .any?
    end

    # Get a specific effect on a participant
    # @param participant [FightParticipant] the participant
    # @param effect_name [String] name of the effect
    # @return [ParticipantStatusEffect, nil] the effect if present
    def get_effect(participant, effect_name)
      effect = StatusEffect.first(name: effect_name)
      return nil unless effect

      ParticipantStatusEffect
        .where(fight_participant_id: participant.id, status_effect_id: effect.id)
        .where { expires_at_round > participant.fight.round_number }
        .first
    end

    # Remove a specific effect from a participant
    # @param participant [FightParticipant] the participant
    # @param effect_name [String] name of the effect to remove
    # @return [Boolean] true if effect was removed
    def remove_effect(participant, effect_name)
      effect = StatusEffect.first(name: effect_name)
      return false unless effect

      deleted = ParticipantStatusEffect
                .where(fight_participant_id: participant.id, status_effect_id: effect.id)
                .delete

      deleted > 0
    end

    # Remove all effects from a participant
    # @param participant [FightParticipant] the participant
    # @return [Integer] number of effects removed
    def remove_all_effects(participant)
      ParticipantStatusEffect
        .where(fight_participant_id: participant.id)
        .delete
    end

    # Cleanse all cleansable debuffs from a participant
    # Used by abilities like "Purify" that remove negative effects
    # @param participant [FightParticipant] the participant
    # @return [Array<String>] names of removed effects
    def cleanse_effects(participant)
      removed_names = []

      active_effects(participant).each do |pse|
        effect = pse.status_effect
        next unless effect

        # Only cleanse debuffs that are marked as cleansable
        next if effect.buff?
        next unless effect.cleansable

        removed_names << effect.name
        pse.destroy
      end

      removed_names
    end

    # Get display data for all active effects on a participant
    # @param participant [FightParticipant] the participant
    # @return [Array<Hash>] effect display data
    def effects_for_display(participant)
      active_effects(participant).map(&:display_info)
    end

    # Get effects grouped by buff/debuff
    # @param participant [FightParticipant] the participant
    # @return [Hash] { buffs: [...], debuffs: [...] }
    def grouped_effects(participant)
      effects = active_effects(participant)

      {
        buffs: effects.select { |e| e.status_effect&.buff? }.map(&:display_info),
        debuffs: effects.reject { |e| e.status_effect&.buff? }.map(&:display_info)
      }
    end

    # =========================================================================
    # COMBAT MECHANICS - DOT Tick Segment Calculation
    # =========================================================================

    # Calculate the segments at which DOT ticks should occur.
    # DOT damage is distributed as individual 1-damage ticks across the round.
    # Example: 10 damage = ticks at segments 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
    # @param total_damage [Integer] total damage for this round
    # @param applied_at_segment [Integer, nil] segment when effect was applied (nil = start of round)
    # @return [Array<Integer>] list of segments when 1-damage ticks occur
    def calculate_dot_tick_segments(total_damage, applied_at_segment = nil)
      return [] if total_damage <= 0

      start_segment = applied_at_segment || 0
      total_segments = GameConfig::Mechanics::SEGMENTS[:total] # 100

      # Distribute ticks evenly across segments
      interval = total_segments.to_f / total_damage

      segments = []
      total_damage.times do |i|
        segment = ((i + 1) * interval).round
        # Only include ticks AFTER applied_at_segment
        segments << segment if segment > start_segment && segment <= total_segments
      end

      segments.sort
    end

    # Get the tick schedule for a DOT effect for the current round.
    # Returns cached schedule or calculates a new one.
    # @param pse [ParticipantStatusEffect] the effect instance
    # @return [Array<Integer>] segments when ticks should occur
    def dot_tick_schedule_for(pse)
      return [] unless pse.status_effect&.effect_type == 'damage_tick'

      # Roll and cache damage if not yet done this round
      unless pse.dot_damage_rolled
        mechanics = pse.status_effect.parsed_mechanics
        damage = DiceNotationService.roll(mechanics['damage'].to_s)
        pse.update(dot_damage_rolled: damage, dot_ticks_processed: 0)
      end

      calculate_dot_tick_segments(pse.dot_damage_rolled, pse.applied_at_segment)
    end

    # Reset DOT tick tracking at start of a new round.
    # Clears cached damage rolls and tick counters for all damage_tick effects.
    # @param fight [Fight] the fight to reset
    def reset_dot_tracking(fight)
      participant_ids = fight.fight_participants_dataset.select_map(:id)
      return if participant_ids.empty?

      # Get all damage_tick effect IDs
      damage_tick_effect_ids = StatusEffect.where(effect_type: 'damage_tick').select_map(:id)
      return if damage_tick_effect_ids.empty?

      # Reset tracking fields for active DOT effects
      ParticipantStatusEffect
        .where(fight_participant_id: participant_ids)
        .where(status_effect_id: damage_tick_effect_ids)
        .update(dot_damage_rolled: nil, dot_ticks_processed: 0, applied_at_segment: nil)
    end

    # Process a single DOT tick for a participant at a specific segment.
    # @param pse [ParticipantStatusEffect] the effect instance
    # @param segment [Integer] current segment being processed
    # @yield [Hash] event hash with tick details
    # @return [Boolean] true if a tick was processed
    def process_dot_tick(pse, segment)
      return false unless pse.status_effect&.effect_type == 'damage_tick'

      participant = pse.fight_participant
      return false unless participant&.can_act?

      # Get tick schedule
      tick_segments = dot_tick_schedule_for(pse)
      return false if tick_segments.empty?

      # Find which tick index this segment corresponds to
      current_tick_index = tick_segments.index(segment)
      return false unless current_tick_index

      # Check if we've already processed this tick
      return false if current_tick_index < (pse.dot_ticks_processed || 0)

      # Process the tick (1 damage)
      participant.accumulate_damage!(1)
      pse.update(dot_ticks_processed: current_tick_index + 1)

      mechanics = pse.status_effect.parsed_mechanics

      if block_given?
        yield({
          type: :damage_tick,
          participant: participant,
          damage: 1,
          tick_number: current_tick_index + 1,
          total_ticks: tick_segments.length,
          effect: pse.status_effect.name,
          damage_type: mechanics['damage_type'],
          segment: segment
        })
      end

      true
    end

    # =========================================================================
    # COMBAT MECHANICS - Damage/Healing Tick Processing (Legacy single-tick)
    # =========================================================================

    # Process damage ticks for all participants in a fight (LEGACY - single tick at segment 50)
    # This is kept for backwards compatibility; new code should use distributed ticks.
    # Yields an event hash for each tick processed
    # @param fight [Fight] the fight to process
    # @param segment [Integer] current segment (for event timing)
    def process_damage_ticks(fight, segment)
      fight.active_participants.each do |participant|
        active_effects(participant).each do |pse|
          next unless pse.status_effect&.effect_type == 'damage_tick'

          mechanics = pse.status_effect.parsed_mechanics
          damage = DiceNotationService.roll(mechanics['damage'].to_s)
          participant.accumulate_damage!(damage)

          yield({
            type: :damage_tick,
            participant: participant,
            damage: damage,
            effect: pse.status_effect.name,
            damage_type: mechanics['damage_type']
          }) if block_given?
        end
      end
    end

    # Process healing ticks for all participants in a fight
    # Uses fractional healing tracked in effect_value
    # @param fight [Fight] the fight to process
    # @param round_number [Integer] current round number
    def process_healing_ticks(fight, round_number)
      fight.active_participants.each do |participant|
        active_effects(participant).each do |pse|
          next unless pse.status_effect&.effect_type == 'healing_tick'

          mechanics = pse.status_effect.parsed_mechanics
          healing_rate = mechanics['healing'].to_f

          # Track fractional healing across rounds
          accumulated = (pse.effect_value.to_f + healing_rate)
          pse.update(effect_value: accumulated)

          if accumulated.to_i >= 1
            heal_amount = accumulated.to_i
            pse.update(effect_value: accumulated - heal_amount)
            participant.heal!(heal_amount)

            yield({
              type: :healing_tick,
              participant: participant,
              amount: heal_amount,
              effect: pse.status_effect.name
            }) if block_given?
          end
        end
      end
    end

    # =========================================================================
    # COMBAT MECHANICS - Shield Absorption
    # =========================================================================

    # Absorb damage with shields, returning remaining damage
    # @param participant [FightParticipant] the participant with shields
    # @param damage [Integer] incoming damage amount
    # @param damage_type [String] type of damage (fire, physical, etc.)
    # @return [Integer] remaining damage after shield absorption
    def absorb_damage_with_shields(participant, damage, damage_type)
      remaining = damage

      active_effects(participant).select { |e| e.status_effect&.effect_type == 'shield' }.each do |pse|
        break if remaining <= 0

        mechanics = pse.status_effect.parsed_mechanics
        types = mechanics['types_absorbed'] || ['all']
        next unless types.include?('all') || types.include?(damage_type)

        shield_hp = pse.effect_value.to_i
        absorbed = [shield_hp, remaining].min
        remaining -= absorbed

        new_shield_hp = shield_hp - absorbed
        if new_shield_hp <= 0
          pse.destroy
        else
          pse.update(effect_value: new_shield_hp)
        end
      end

      remaining
    end

    # =========================================================================
    # COMBAT MECHANICS - Damage Type Modifiers
    # =========================================================================

    # Get the damage type multiplier (vulnerability/resistance/immunity)
    # @param participant [FightParticipant] the participant
    # @param damage_type [String] the type of damage (fire, cold, etc.)
    # @return [Float] multiplier to apply (2.0 = vulnerable, 0.5 = resistant, 0.0 = immune)
    def damage_type_multiplier(participant, damage_type)
      multiplier = 1.0

      active_effects(participant).select { |e| e.status_effect&.effect_type == 'incoming_damage' }.each do |pse|
        mechanics = pse.status_effect.parsed_mechanics
        effect_damage_type = mechanics['damage_type']

        # Check if this effect applies to the damage type
        next unless effect_damage_type == 'all' || effect_damage_type == damage_type

        # Only use multiplier if present (new-style effects)
        if mechanics['multiplier']
          multiplier *= mechanics['multiplier'].to_f
        end
      end

      multiplier
    end

    # Get flat damage reduction from damage_reduction effects
    # @param participant [FightParticipant] the participant
    # @param damage_type [String] the type of damage
    # @return [Integer] total flat reduction to apply
    def flat_damage_reduction(participant, damage_type)
      reduction = 0

      active_effects(participant).select { |e| e.status_effect&.effect_type == 'damage_reduction' }.each do |pse|
        mechanics = pse.status_effect.parsed_mechanics
        types = mechanics['types'] || ['all']

        next unless types.include?('all') || types.include?(damage_type)

        reduction += (mechanics['flat_reduction'].to_i * (pse.stack_count || 1))
      end

      reduction
    end

    # Get overall protection reduction (applies to cumulative damage, not per-hit)
    # Unlike damage_reduction which applies to each incoming attack, protection
    # reduces the total cumulative damage for threshold calculations.
    # DOT damage bypasses protection entirely.
    # @param participant [FightParticipant] the participant
    # @param damage_type [String] the type of damage (for type-specific protection)
    # @return [Integer] total protection to subtract from cumulative
    def overall_protection(participant, damage_type)
      protection = 0

      active_effects(participant).select { |e| e.status_effect&.effect_type == 'protection' }.each do |pse|
        mechanics = pse.status_effect.parsed_mechanics
        types = mechanics['types'] || ['all']

        # Only apply if damage type matches OR types includes 'all'
        next unless types.include?('all') || types.include?(damage_type)

        protection += (mechanics['flat_protection'].to_i * (pse.stack_count || 1))
      end

      protection
    end

    # =========================================================================
    # COMBAT MECHANICS - Action Restrictions
    # =========================================================================

    # Check if participant can use main action (stunned check)
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if main action is available
    def can_use_main_action?(participant)
      !active_effects(participant).any? do |e|
        e.status_effect&.effect_type == 'action_restriction' &&
          e.status_effect.parsed_mechanics['blocks_main']
      end
    end

    # Check if participant can use tactical action (dazed/stunned check)
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if tactical action is available
    def can_use_tactical_action?(participant)
      !active_effects(participant).any? do |e|
        e.status_effect&.effect_type == 'action_restriction' &&
          e.status_effect.parsed_mechanics['blocks_tactical']
      end
    end

    # =========================================================================
    # COMBAT MECHANICS - Targeting Restrictions
    # =========================================================================

    # Get the ID of a participant that must be targeted (taunt)
    # @param participant [FightParticipant] the participant under taunt
    # @return [Integer, nil] ID of the taunter, or nil if not taunted
    def must_target(participant)
      taunt = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'targeting_restriction'
      end
      return nil unless taunt

      taunt.status_effect.parsed_mechanics['must_target_id']
    end

    # Get the penalty for attacking someone other than the taunter
    # @param participant [FightParticipant] the participant under taunt
    # @return [Integer] penalty to apply (negative number)
    def taunt_penalty(participant)
      taunt = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'targeting_restriction'
      end
      return 0 unless taunt

      taunt.status_effect.parsed_mechanics['penalty_otherwise'].to_i
    end

    # Get the IDs of participants that this participant cannot target
    # Used for protection effects like "Sanctuary" that prevent being attacked
    # @param participant [FightParticipant] the participant trying to attack
    # @return [Array<Integer>] IDs of protected participants
    def cannot_target_ids(participant)
      protected_ids = []

      active_effects(participant).each do |pse|
        next unless pse.status_effect&.effect_type == 'targeting_restriction'

        mechanics = pse.status_effect.parsed_mechanics
        if mechanics['cannot_target_id']
          protected_ids << mechanics['cannot_target_id'].to_i
        end
      end

      protected_ids
    end

    # =========================================================================
    # COMBAT MECHANICS - Fear Effects
    # =========================================================================

    # Get the ID of participant that the target is afraid of
    # @param participant [FightParticipant] the frightened participant
    # @return [Integer, nil] ID of the fear source, or nil if not frightened
    def fear_source(participant)
      fear = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'fear'
      end
      return nil unless fear

      fear.status_effect.parsed_mechanics['flee_from_id']
    end

    # Get attack penalty from fear
    # @param participant [FightParticipant] the frightened participant
    # @return [Integer] penalty to apply to attacks (negative number)
    def fear_attack_penalty(participant)
      fear = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'fear'
      end
      return 0 unless fear

      fear.status_effect.parsed_mechanics['attack_penalty'].to_i
    end

    # =========================================================================
    # COMBAT MECHANICS - Grapple Effects
    # =========================================================================

    # Check if participant is currently grappled
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if grappled
    def is_grappled?(participant)
      active_effects(participant).any? do |e|
        e.status_effect&.effect_type == 'grapple'
      end
    end

    # Get the ID of the participant who is grappling this participant
    # @param participant [FightParticipant] the grappled participant
    # @return [Integer, nil] ID of the grappler, or nil if not grappled
    def grappler_for(participant)
      grapple = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'grapple'
      end
      return nil unless grapple

      # The grappler ID is stored in mechanics as 'grappled_by_id'
      grapple.status_effect.parsed_mechanics['grappled_by_id'] ||
        grapple.applied_by_participant_id
    end

    # Get the participant ID that this participant is grappling
    # (Find all participants with grapple effect applied by this participant)
    # @param participant [FightParticipant] the grappler
    # @return [Array<Integer>] IDs of grappled participants
    def grappled_by(participant)
      return [] unless participant&.fight

      ParticipantStatusEffect
        .join(:status_effects, id: :status_effect_id)
        .where(Sequel[:participant_status_effects][:applied_by_participant_id] => participant.id)
        .where(Sequel[:status_effects][:effect_type] => 'grapple')
        .where { Sequel[:participant_status_effects][:expires_at_round] > participant.fight.round_number }
        .select_map(Sequel[:participant_status_effects][:fight_participant_id])
    end

    # =========================================================================
    # COMBAT MECHANICS - Burning Spread
    # =========================================================================

    # Process burning spread at end of round
    # Burning can spread to adjacent participants
    # @param fight [Fight] the fight to process
    def process_burning_spread(fight)
      fight.active_participants.each do |participant|
        burning = active_effects(participant).find do |e|
          e.status_effect&.name == 'burning'
        end
        next unless burning

        mechanics = burning.status_effect.parsed_mechanics
        next unless mechanics['spreadable']

        # Find adjacent participants without burning
        fight.active_participants.each do |adjacent|
          next if adjacent == participant
          next if has_effect?(adjacent, 'burning')
          next unless participant.hex_distance_to(adjacent) <= 1

          # 50% chance to spread
          next unless rand < 0.5

          apply_by_name(
            participant: adjacent,
            effect_name: 'burning',
            duration_rounds: 2,
            applied_by: nil
          )

          yield({
            type: :burning_spread,
            from: participant,
            to: adjacent
          }) if block_given?
        end
      end
    end

    # Extinguish burning (player can spend action to remove)
    # @param participant [FightParticipant] the burning participant
    # @return [Boolean] true if burning was removed
    def extinguish(participant)
      burning = active_effects(participant).find do |e|
        e.status_effect&.name == 'burning'
      end
      return false unless burning

      mechanics = burning.status_effect.parsed_mechanics
      return false unless mechanics['extinguish_action']

      burning.destroy
      true
    end

    # =========================================================================
    # COMBAT MECHANICS - Movement Speed Modifiers
    # =========================================================================

    # Get the movement speed multiplier from effects
    # @param participant [FightParticipant] the participant
    # @return [Float] multiplier to apply to movement (1.0 = normal, 0.5 = slowed)
    def movement_speed_multiplier(participant)
      multiplier = 1.0

      active_effects(participant).each do |pse|
        next unless pse.status_effect&.effect_type == 'movement'

        mechanics = pse.status_effect.parsed_mechanics
        if mechanics['speed_multiplier']
          multiplier *= mechanics['speed_multiplier'].to_f
        end
      end

      multiplier
    end

    # Check if participant is prone
    # @param participant [FightParticipant] the participant
    # @return [Boolean] true if prone
    def is_prone?(participant)
      active_effects(participant).any? do |e|
        e.status_effect&.effect_type == 'movement' &&
          e.status_effect.parsed_mechanics['prone']
      end
    end

    # Get the stand cost if prone
    # @param participant [FightParticipant] the participant
    # @return [Integer] movement cost to stand up
    def stand_cost(participant)
      prone_effect = active_effects(participant).find do |e|
        e.status_effect&.effect_type == 'movement' &&
          e.status_effect.parsed_mechanics['prone']
      end
      return 0 unless prone_effect

      prone_effect.status_effect.parsed_mechanics['stand_cost'].to_i
    end

    # =========================================================================
    # COMBAT MECHANICS - Healing Modifiers
    # =========================================================================

    # Get the healing multiplier from status effects
    # (1.5 = amplified healing, 0.5 = reduced healing, 0 = no healing)
    # @param participant [FightParticipant] the participant
    # @return [Float] multiplier to apply to healing received
    def healing_modifier(participant)
      multiplier = 1.0

      active_effects(participant).each do |pse|
        next unless pse.status_effect&.effect_type == 'healing'

        mechanics = pse.status_effect.parsed_mechanics
        if mechanics['multiplier']
          multiplier *= mechanics['multiplier'].to_f
        end
      end

      multiplier
    end

    # =========================================================================
    # COMBAT MECHANICS - Outgoing Damage Bonus
    # =========================================================================

    # Get flat outgoing damage bonus from empowered effects
    # @param participant [FightParticipant] the participant
    # @return [Integer] bonus damage to add to outgoing attacks
    def outgoing_damage_bonus(participant)
      bonus = 0

      active_effects(participant).each do |pse|
        next unless pse.status_effect&.effect_type == 'outgoing_damage'

        mechanics = pse.status_effect.parsed_mechanics
        if mechanics['bonus']
          bonus += (mechanics['bonus'].to_i * (pse.stack_count || 1))
        end
      end

      bonus
    end
  end
end
