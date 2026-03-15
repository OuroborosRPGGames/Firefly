# frozen_string_literal: true

# Handles skill check attempts for delve blockers.
class DelveSkillCheckService
  # Result struct for skill check attempts
  Result = Struct.new(:success, :message, :data, keyword_init: true)

  class << self
    # Attempt to clear a blocker
    # @param participant [DelveParticipant] the attempting participant
    # @param blocker [DelveBlocker] the blocker to clear
    # @param options [Hash] additional options
    # @return [Result] the result of the attempt
    def attempt!(participant, blocker, options = {})
      # Spend time
      time_cost = Delve.action_time_seconds(:skill_check) || 15
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out before you can attempt the obstacle!",
          data: { time_expired: true }
        )
      end

      # Get stat and calculate modifier
      stat_abbrev = blocker.stat_for_check
      char_instance = participant.character_instance
      stat_value = stat_value(char_instance, stat_abbrev)
      stat_calc = GameConfig::Mechanics::STAT_CALCULATION
      stat_modifier = (stat_value - stat_calc[:base]) / stat_calc[:divisor]

      # Calculate DC
      base_dc = GameSetting.integer('delve_base_skill_dc') || 10
      level_mod = (GameSetting.integer('delve_dc_per_level') || 2) * participant.current_level
      easier_mod = blocker.easier_attempts || 0
      party_bonus = options[:party_bonus] || 0

      dc = base_dc + level_mod - easier_mod

      # Willpower: spend 1 die for +1d8
      extra_dice = 0
      if options[:use_willpower] && participant.use_willpower!
        extra_dice = 1
      end

      # Roll 2d8 + stat modifier + party bonus (+ willpower dice)
      roll = roll_skill_check(stat_modifier + party_bonus, extra_dice: extra_dice)
      total = roll[:total]
      success = total >= dc

      if success
        # Only permanently clear destructible blockers (barricade/locked_door)
        # Gap/narrow remain as obstacles — participant just marks having crossed
        blocker.clear! unless blocker.causes_damage_on_fail?
        participant.mark_blocker_cleared!(blocker.id)

        Result.new(
          success: true,
          message: success_message(blocker, roll, dc),
          data: { roll: roll, dc: dc, cleared: true, roll_result: roll[:roll_result] }
        )
      else
        handle_failure(participant, blocker, roll, dc)
      end
    end

    # Make a blocker easier to pass
    # @param participant [DelveParticipant] the participant
    # @param blocker [DelveBlocker] the blocker
    # @return [Result]
    def make_easier!(participant, blocker)
      time_cost = Delve.action_time_seconds(:easier) || 30
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out before you can make the obstacle easier!",
          data: { time_expired: true }
        )
      end

      blocker.increment_easier_attempts!

      Result.new(
        success: true,
        message: "You study the #{blocker.blocker_type.tr('_', ' ')}, " \
                 "lowering the difficulty (now #{blocker.effective_difficulty}).",
        data: { easier_attempts: blocker.easier_attempts, new_dc: blocker.effective_difficulty }
      )
    end

    # Calculate party bonus for skill checks
    # +2 for each party member who already succeeded (gap/narrow only)
    # @param participant [DelveParticipant] the current participant
    # @param blocker [DelveBlocker] the blocker
    # @return [Integer] bonus amount
    def party_bonus(participant, blocker)
      return 0 unless blocker.causes_damage_on_fail?

      # Count party members who cleared this blocker
      delve = participant.delve
      cleared_count = delve.active_participants.count do |p|
        p.id != participant.id && p.has_cleared_blocker?(blocker.id)
      end

      cleared_count * 2
    end

    private

    def stat_value(character_instance, stat_abbrev)
      default_stat = GameConfig::Mechanics::STAT_CALCULATION[:base]
      return default_stat unless character_instance

      StatAllocationService.get_stat_value(character_instance, stat_abbrev) ||
        StatAllocationService.get_stat_value(character_instance, stat_abbrev.upcase) ||
        default_stat
    end

    def roll_skill_check(modifier, extra_dice: 0)
      roll_result = DiceRollService.roll_2d8_exploding(modifier)

      # Extra dice from willpower
      willpower_rolls = []
      extra_dice.times { willpower_rolls << rand(1..8) }

      total = roll_result.total + willpower_rolls.sum

      {
        dice: roll_result.base_dice,
        all_dice: roll_result.dice,
        explosions: roll_result.explosions,
        willpower_rolls: willpower_rolls,
        modifier: modifier,
        total: total,
        roll_result: roll_result
      }
    end

    def format_roll(roll, dc)
      parts = ["[#{roll[:dice].join(', ')}]"]

      if roll[:explosions]&.any?
        explosion_values = roll[:all_dice][2..] || []
        parts << "EXPLODE!#{explosion_values.map { |e| "+#{e}" }.join('')}" if explosion_values.any?
      end

      if roll[:willpower_rolls]&.any?
        parts << "WP:+#{roll[:willpower_rolls].join('+')}"
      end

      if roll[:modifier] && roll[:modifier] != 0
        sign = roll[:modifier] > 0 ? '+' : ''
        parts << "#{sign}#{roll[:modifier]}"
      end

      parts << "= #{roll[:total]} vs DC #{dc}"
      parts.join(' ')
    end

    def success_message(blocker, roll, dc)
      action = case blocker.blocker_type
               when 'barricade' then 'break through the barricade'
               when 'locked_door' then 'pick the lock'
               when 'gap' then 'leap across the gap'
               when 'narrow' then 'balance across the narrow ledge'
               else 'clear the obstacle'
               end

      "You successfully #{action}! #{format_roll(roll, dc)}"
    end

    def handle_failure(participant, blocker, roll, dc)
      if blocker.causes_damage_on_fail?
        # Gap/narrow: take damage but still make it across
        # Gap/narrow don't get cleared — they remain as obstacles but the participant
        # is marked as having crossed (giving them experience bonus next time)
        damage = participant.current_level
        participant.take_hp_damage!(damage)

        if participant.is_a?(DelveParticipant) && !participant.active?
          action = blocker.blocker_type == 'gap' ? 'jumping the gap' : 'crossing the narrow ledge'
          return Result.new(
            success: false,
            message: "You fail #{action} and are incapacitated, taking #{damage} damage! #{format_roll(roll, dc)}",
            data: { roll: roll, dc: dc, damage: damage, cleared: false, defeated: true, roll_result: roll[:roll_result] }
          )
        end

        participant.mark_blocker_cleared!(blocker.id)

        action = blocker.blocker_type == 'gap' ? 'jumping the gap' : 'crossing the narrow ledge'

        Result.new(
          success: true,
          message: "You fail #{action} gracefully but make it across, taking #{damage} damage! #{format_roll(roll, dc)}",
          data: { roll: roll, dc: dc, damage: damage, cleared: true, roll_result: roll[:roll_result] }
        )
      else
        # Barricade/locked door: just fail, try again (narrative, not error)
        action = blocker.blocker_type == 'barricade' ? 'breaking through' : 'picking the lock'

        Result.new(
          success: true,
          message: "You fail at #{action}. Try again, or use 'easier' to lower the DC. #{format_roll(roll, dc)}",
          data: { roll: roll, dc: dc, cleared: false, roll_result: roll[:roll_result] }
        )
      end
    end
  end
end
