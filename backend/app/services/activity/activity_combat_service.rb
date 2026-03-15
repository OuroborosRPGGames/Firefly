# frozen_string_literal: true

# Handles combat round integration for the Activity System.
#
# Combat rounds:
# - Pause activity, create actual Fight instance
# - Use existing combat system with all participants vs NPCs
# - NPCs defined by combat_npc_ids (array of NpcArchetype IDs)
# - Activity resumes when Fight ends
# - Fight outcome affects activity:
#   - Win → progress to next round
#   - Lose → handle as activity failure (may branch or end)
class ActivityCombatService
  class CombatError < StandardError; end

  # Result structure for combat round
  CombatResult = Struct.new(
    :fight_created,
    :fight_id,
    :npc_count,
    :participant_count,
    :is_finale,
    :emit_text,
    keyword_init: true
  )

  class << self
    # Start a combat round by creating a fight
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The combat round
    # @return [CombatResult]
    def start_combat(instance, round)
      raise CombatError, 'Not a combat round' unless round.combat?
      raise CombatError, 'No active participants' if instance.active_participants.empty?
      raise CombatError, 'Already in combat' if instance.paused_for_combat?

      npcs = round.combat_npcs
      raise CombatError, 'No NPCs defined for combat round' if npcs.empty?

      # Apply finale modifier to NPC levels if this is the finale
      level_modifier = round.finale? ? instance.finale_npc_modifier : 0

      fight = create_fight_via_service(instance, round, npcs, level_modifier)

      # Pause activity for fight
      instance.pause_for_fight!(fight)

      # Apply NPC AI decisions for the first round
      fight.fight_participants.each do |p|
        next unless p.is_npc && !p.is_knocked_out && !p.input_complete
        CombatAIService.new(p).apply_decisions!
      end

      # Reset input deadline now that NPCs have auto-submitted
      fight.reset_input_deadline!
      fight.save_changes

      CombatResult.new(
        fight_created: true,
        fight_id: fight.id,
        npc_count: npcs.count,
        participant_count: instance.active_participants.count,
        is_finale: round.finale?,
        emit_text: round.emit_text
      )
    end

    # Check if fight is complete and handle result
    # @param instance [ActivityInstance]
    # @return [Hash, nil] { success: Boolean, can_continue: Boolean } or nil if fight ongoing
    def resolve_fight_result(instance)
      return nil unless instance.paused_for_combat?

      fight = instance.active_fight
      return nil unless fight
      return nil if fight.ongoing?

      # Fight is complete - determine outcome
      success = fight_was_won?(fight, instance)

      # Resume activity
      instance.resume_from_fight!

      # Apply consequences
      unless success
        apply_combat_failure(instance, instance.current_round)
      end

      { success: success, can_continue: success || !instance.current_round&.branches_on_failure? }
    end

    # Resume activity after fight ends (called by fight completion callback)
    # @param fight [Fight]
    # @param victory [Boolean] Whether players won
    def on_fight_complete(fight, victory)
      # Find activity paused for this fight
      instance = ::ActivityInstance.first(paused_for_fight_id: fight.id)
      return unless instance

      instance.resume_from_fight!

      if victory
        # Progress to next round
        ActivityService.advance_round(instance)
      else
        # Handle failure
        round = instance.current_round
        apply_combat_failure(instance, round)

        if round&.branches_on_failure? && round.fail_branch_to
          # fail_branch_to is an ActivityRound ID, so jump to that round.
          ActivityService.advance_with_branch(instance, round.fail_branch_to)
        elsif round&.can_fail_repeat?
          # Repeat round (will be handled by activity service)
        else
          # Activity ends in failure
          ActivityService.complete_activity(instance, success: false)
        end
      end
    end

    private

    # Create a Fight via FightService (preferred path)
    def create_fight_via_service(instance, round, npcs, level_modifier)
      room = instance.room
      participants = instance.active_participants

      fight = FightService.create_fight(room: room, activity_instance_id: instance.id)
      balance_config = resolve_balanced_configuration(instance, participants, npcs, round)

      # Add player participants (side 1)
      participants.each do |p|
        ci = p.character_instance
        next unless ci

        FightService.add_combatant(fight, ci)
      end

      archetypes_by_id = {}
      npcs.each { |archetype| archetypes_by_id[archetype.id] = archetype if archetype&.id }

      composition = balance_config[:composition] || {}
      stat_modifiers = balance_config[:stat_modifiers] || {}

      # Spawn balanced NPC composition (side 2)
      composition.each do |archetype_id, config|
        id = archetype_id.to_i
        npc_archetype = archetypes_by_id[id] || NpcArchetype[id]
        next unless npc_archetype

        count = config[:count] || config['count'] || 1
        npc_level = (npc_archetype.level || 1) + level_modifier
        stat_modifier = stat_modifier_for(stat_modifiers, archetype_id, id)

        count.times do
          FightService.spawn_npc_combatant(
            fight,
            npc_archetype,
            level: npc_level,
            stat_modifier: stat_modifier
          )
        end
      end

      fight
    end

    # Resolve NPC composition/stat modifiers using battle balancing.
    # Falls back to one-per-archetype composition if balancing fails.
    def resolve_balanced_configuration(instance, participants, npcs, round)
      fallback = default_balance_configuration(npcs)
      difficulty = round.combat_difficulty_level

      pc_ids = participants.filter_map do |participant|
        ci = participant.character_instance
        char = ci&.character || participant.character
        char&.id
      end.uniq

      mandatory_ids = npcs.filter_map(&:id)
      return fallback if pc_ids.empty? || mandatory_ids.empty?

      balancer = BattleBalancingService.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_ids,
        optional_archetype_ids: []
      )
      result = balancer.balance!

      variant_key = map_activity_difficulty_to_variant(difficulty)
      variants = result[:difficulty_variants] || {}
      selected_variant = variants[variant_key] || variants['normal'] || {}

      {
        composition: selected_variant[:composition] || selected_variant['composition'] || result[:composition] || fallback[:composition],
        stat_modifiers: selected_variant[:stat_modifiers] || selected_variant['stat_modifiers'] || result[:stat_modifiers] || {}
      }
    rescue StandardError => e
      warn "[ActivityCombatService] Failed to balance combat round #{round&.id} for activity #{instance&.id}: #{e.message}"
      fallback
    end

    def default_balance_configuration(npcs)
      composition = {}
      npcs.each do |archetype|
        next unless archetype&.id

        composition[archetype.id] ||= { count: 0 }
        composition[archetype.id][:count] += 1
      end

      { composition: composition, stat_modifiers: {} }
    end

    def map_activity_difficulty_to_variant(difficulty)
      case difficulty.to_s.strip.downcase
      when 'easy'
        'easy'
      when 'hard'
        'hard'
      when 'deadly'
        'nightmare'
      else
        'normal'
      end
    end

    def stat_modifier_for(modifiers, raw_key, int_key)
      modifiers[raw_key] || modifiers[int_key] || modifiers[int_key.to_s] || 0.0
    end

    # Determine if players won the fight
    def fight_was_won?(fight, instance)
      return fight.player_victory? if fight.player_victory?

      winner = fight.winner
      return winner == 'players' || winner == 'party' if winner

      # Fallback: check if all participants are still alive
      instance.active_participants.all? do |p|
        ci = p.character_instance
        ci && ci.current_hp && ci.current_hp > 0
      end
    end

    # Apply combat failure consequences
    def apply_combat_failure(instance, round)
      return unless round

      case round.fail_consequence_type
      when 'difficulty'
        instance.add_difficulty_modifier!(1)
      when 'harder_finale'
        instance.add_finale_modifier!(1)
      end
    end
  end
end
