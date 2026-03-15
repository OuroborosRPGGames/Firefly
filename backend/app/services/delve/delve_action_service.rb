# frozen_string_literal: true

require_relative '../concerns/result_handler'
require_relative '../concerns/delve_guards'

# Handles non-movement actions in a delve: combat, flee, recovery actions.
# Note: Search was removed - treasure is visible on room entry.
# Note: Traps are now directional obstacles handled by DelveMovementService.
class DelveActionService
  extend ResultHandler
  extend DelveGuards

  class << self
    # Fight a monster in the current room
    # @param participant [DelveParticipant]
    # @return [Result]
    def fight!(participant)
      guard = validate_for_action(participant)
      return guard if guard

      room = participant.current_room
      delve = participant.delve

      # Check for roving DelveMonster records first, then fall back to static room monsters
      roving_monsters = delve.monsters_in_room(room)
      monster_record = roving_monsters.first

      unless monster_record || room.has_monster?
        return error("There's nothing to fight here.")
      end

      # Spend combat time (5 minutes)
      time_cost = Delve.action_time_seconds(:combat) || Delve::ACTION_TIMES_SECONDS[:combat]
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out during combat!",
          data: { time_expired: true }
        )
      end

      # Combat resolution - use roving monster if available, else static room type
      monster_type = monster_record&.monster_type || room.monster_type
      monster_tier = DelveGeneratorService::MONSTERS.index(monster_type) || 0

      # Simple combat: damage scales with monster tier and level
      base_damage = 5 + monster_tier * 3 + room.level * 2

      # Apply study bonus (-2 damage taken if studied)
      study_bonus = participant.study_bonus_for(monster_type)
      base_damage = [base_damage - study_bonus, 0].max

      damage = (base_damage * (0.5 + rand * 0.5)).to_i
      participant.take_hp_damage!(damage)

      # Lethal damage ends the run immediately - no victory rewards.
      if participant.respond_to?(:active?) && !participant.active?
        return Result.new(
          success: false,
          message: "The #{monster_type} overwhelms you! You take #{damage} damage and collapse.",
          data: {
            monster: monster_type,
            damage_taken: damage,
            total_damage: participant.total_damage,
            defeated: true,
            status: participant.status,
            remaining_loot: participant.loot_collected
          }
        )
      end

      # Victory - deactivate roving monster and/or clear static room monster
      if monster_record
        monster_record.update(is_active: false)
      end
      room.clear_monster! if room.has_monster?
      participant.add_kill!

      # Bonus loot from combat
      bonus_loot = (10 + monster_tier * 5 + room.level * 3) * (rand(0.5..1.5))
      bonus_loot = bonus_loot.to_i
      participant.add_loot!(bonus_loot)

      Result.new(
        success: true,
        message: "You defeat the #{monster_type}! You take #{damage} damage in the fight.\nYou find #{bonus_loot} gold on the corpse.",
        data: {
          monster: monster_type,
          damage_taken: damage,
          total_damage: participant.total_damage,
          kills: participant.monsters_killed,
          bonus_loot: bonus_loot,
          total_loot: participant.loot_collected,
          time_remaining: participant.time_remaining_seconds
        }
      )
    end

    # Exit the dungeon (flee)
    # @param participant [DelveParticipant]
    # @return [Result]
    def flee!(participant)
      delve = participant.delve
      return error("You're not in a delve.") unless delve
      return error("You've already extracted.") if participant.extracted?
      if participant.respond_to?(:active?) && !participant.active?
        return error("You can no longer flee this delve.")
      end

      loot = participant.loot_collected || 0

      # End any active fight before extracting
      active_fight = FightService.find_active_fight(participant.character_instance)
      active_fight&.complete!

      participant.extract!

      # Return character to pre-delve room (with safety fallback)
      restore_room = safe_destination(participant)
      participant.character_instance.update(current_room_id: restore_room.id) if restore_room

      # Release delve rooms back to pool only when nobody is still delving.
      if delve.active_participants.empty?
        TemporaryRoomPoolService.release_delve_rooms(delve)
        if delve.respond_to?(:abandon!) && delve.respond_to?(:status) &&
           !%w[completed abandoned failed].include?(delve.status)
          delve.abandon!
        end
      end

      Result.new(
        success: true,
        message: "You flee the dungeon with #{loot} gold!",
        data: {
          loot: loot,
          rooms_explored: participant.rooms_explored,
          monsters_killed: participant.monsters_killed,
          damage_taken: participant.total_damage
        }
      )
    end

    # Get current status
    # @param participant [DelveParticipant]
    # @return [Result]
    def status(participant)
      return error("You're not in a delve.") unless participant.delve

      delve = participant.delve

      hp_display = "#{participant.current_hp || 6}/#{participant.max_hp || 6}"
      willpower_display = participant.willpower_dice || 0
      studied_display = (participant.studied_monsters || []).any? ?
        (participant.studied_monsters || []).join(', ') : 'None'

      status_text = <<~HTML
        <h3>#{delve.name}</h3>
        <div class="text-sm opacity-70">#{delve.difficulty.capitalize} &middot; Level #{participant.current_level || 1}</div>
        <div class="mt-2">Time: <strong>#{format('%d:%02d', (participant.time_remaining_seconds || 0) / 60, (participant.time_remaining_seconds || 0) % 60)}</strong> / #{delve.time_limit_minutes} min</div>
        <div class="divider my-1"></div>
        <div><strong>HP:</strong> #{hp_display} &nbsp; <strong>Willpower:</strong> #{willpower_display}</div>
        <div><strong>Studied:</strong> #{studied_display}</div>
        <div class="divider my-1"></div>
        <div><strong>Loot:</strong> #{participant.loot_collected || 0} gold &nbsp; <strong>Rooms:</strong> #{participant.rooms_explored || 0}</div>
        <div><strong>Kills:</strong> #{participant.monsters_killed || 0} &nbsp; <strong>Damage Taken:</strong> #{participant.total_damage}</div>
      HTML

      Result.new(
        success: true,
        message: status_text.strip,
        data: {
          delve_name: delve.name,
          difficulty: delve.difficulty,
          current_level: participant.current_level,
          time_remaining: participant.time_remaining_seconds,
          time_limit: delve.time_limit_minutes,
          loot_collected: participant.loot_collected,
          rooms_explored: participant.rooms_explored,
          monsters_killed: participant.monsters_killed,
          damage_taken: participant.total_damage,
          status: participant.status,
          current_hp: participant.current_hp,
          max_hp: participant.max_hp,
          willpower_dice: participant.willpower_dice,
          studied_monsters: participant.studied_monsters
        }
      )
    end

    # ====== New Actions ======

    # Recover action - heal all damage for 5 minutes
    # @param participant [DelveParticipant]
    # @return [Result]
    def recover!(participant)
      guard = validate_for_action(participant)
      return guard if guard
      combat_guard = validate_not_in_combat(participant)
      return combat_guard if combat_guard
      return error("You're already at full health.") if participant.full_health?

      time_cost = Delve.action_time_seconds(:recover) || Delve::ACTION_TIMES_SECONDS[:recover]
      time_result = participant.spend_time_seconds!(time_cost)

      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out while recovering!",
          data: { time_expired: true }
        )
      end

      participant.heal!

      Result.new(
        success: true,
        message: "You rest and recover, healing all damage. (HP: #{participant.current_hp}/#{participant.max_hp})",
        data: {
          current_hp: participant.current_hp,
          max_hp: participant.max_hp,
          time_remaining: participant.time_remaining_seconds
        }
      )
    end

    # Focus action - gain 1 willpower die for 1 minute
    # @param participant [DelveParticipant]
    # @return [Result]
    def focus!(participant)
      guard = validate_for_action(participant)
      return guard if guard
      combat_guard = validate_not_in_combat(participant)
      return combat_guard if combat_guard
      max_wp = GameConfig::Mechanics::WILLPOWER[:max_dice]
      return error("Your willpower is already at maximum (#{max_wp}).") if (participant.willpower_dice || 0) >= max_wp

      time_cost = Delve.action_time_seconds(:focus) || Delve::ACTION_TIMES_SECONDS[:focus]
      time_result = participant.spend_time_seconds!(time_cost)

      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out while focusing!",
          data: { time_expired: true }
        )
      end

      participant.add_willpower!

      Result.new(
        success: true,
        message: "You focus your mind, gaining a willpower die. (Total: #{participant.willpower_dice})",
        data: {
          willpower_dice: participant.willpower_dice,
          time_remaining: participant.time_remaining_seconds
        }
      )
    end

    # Study action - study an enemy type for combat bonuses
    # @param participant [DelveParticipant]
    # @param monster_type [String] the monster type to study
    # @return [Result]
    def study!(participant, monster_type)
      guard = validate_for_action(participant)
      return guard if guard
      return error("You've already studied this enemy type.") if participant.has_studied?(monster_type)

      time_cost = Delve.action_time_seconds(:study) || Delve::ACTION_TIMES_SECONDS[:study]
      time_result = participant.spend_time_seconds!(time_cost)

      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out while studying!",
          data: { time_expired: true }
        )
      end

      participant.add_study!(monster_type)

      Result.new(
        success: true,
        message: "You study the #{monster_type}, gaining +2 on rolls and +2 damage thresholds against them.",
        data: {
          studied: monster_type,
          studied_monsters: participant.studied_monsters,
          time_remaining: participant.time_remaining_seconds
        }
      )
    end

    # Handle defeat (wrapper for participant method)
    # @param participant [DelveParticipant]
    # @return [Result]
    def handle_defeat!(participant)
      loot_lost = participant.handle_defeat!

      Result.new(
        success: false,
        message: "You have been defeated! You lose #{loot_lost} gold and are ejected from the dungeon.",
        data: {
          loot_lost: loot_lost,
          remaining_loot: participant.loot_collected
        }
      )
    end

    # Handle timeout (wrapper for participant method)
    # @param participant [DelveParticipant]
    # @return [Result]
    def handle_timeout!(participant)
      loot_lost = participant.handle_timeout!

      Result.new(
        success: false,
        message: "Time has run out! You lose #{loot_lost} gold and are forced to flee.",
        data: {
          loot_lost: loot_lost,
          remaining_loot: participant.loot_collected
        }
      )
    end

    private

    # Find a safe non-temporary room to return to after leaving a delve.
    # Falls back to last known non-temporary room or tutorial spawn.
    def safe_destination(participant)
      ci = participant.character_instance
      return nil unless ci

      if participant.pre_delve_room_id
        room = Room[participant.pre_delve_room_id]
        return room if room && !room.temporary?
      end

      ci.safe_fallback_room
    end

  end
end
