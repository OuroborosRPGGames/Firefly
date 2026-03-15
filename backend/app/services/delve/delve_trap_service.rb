# frozen_string_literal: true

require_relative '../concerns/result_handler'

# Handles timing-based trap generation and passage attempts.
# Traps are directional obstacles - they block movement in a specific direction.
# When moving through a trapped direction, player must time their passage.
class DelveTrapService
  extend ResultHandler

  class << self
    # Generate a trap blocking a specific direction from a room
    # @param room [DelveRoom] the room
    # @param direction [String] the direction the trap blocks
    # @param level [Integer] dungeon level
    # @param era [Symbol, String] the current era for theming
    # @return [DelveTrap] the generated trap
    def generate!(room, direction, level, era)
      timing_a, timing_b = DelveTrap.generate_timings
      theme = DelveTrap.random_theme(era)

      DelveTrap.create(
        delve_room_id: room.id,
        direction: direction,
        timing_a: timing_a,
        timing_b: timing_b,
        damage: level, # 1 HP per level
        trap_theme: theme
      )
    end

    # Find trap blocking a specific direction from a room
    # @param room [DelveRoom] the room
    # @param direction [String] the direction to check
    # @return [DelveTrap, nil] the trap if one exists
    def trap_in_direction(room, direction)
      DelveTrap.first(delve_room_id: room.id, direction: direction, disabled: false)
    end

    # Get initial sequence display when first encountering trap
    # @param trap [DelveTrap] the trap
    # @param participant_id [Integer, nil] optional participant ID for deterministic sequence
    # @return [Hash] sequence data
    def get_initial_sequence(trap, participant_id = nil)
      # Use deterministic start for consistent sequence viewing
      # Start range from GameConfig::DelveTrap::SEQUENCE_START_RANGE
      start_range = GameConfig::DelveTrap::SEQUENCE_START_RANGE
      if participant_id
        seed = trap.id * 1000 + participant_id
        range_size = start_range.size
        start_point = start_range.min + (seed % range_size)
      else
        start_point = rand(start_range)
      end
      length = GameConfig::DelveTrap::INITIAL_SEQUENCE_LENGTH

      sequence = trap.generate_sequence(start_point, length)

      {
        start_point: start_point,
        length: length,
        sequence: sequence,
        trap_theme: trap.trap_theme,
        description: trap.description,
        formatted: format_sequence(sequence)
      }
    end

    # Listen for more trap timing (extend sequence)
    # @param participant [DelveParticipant] the participant
    # @param trap [DelveTrap] the trap
    # @param current_start [Integer] current sequence start
    # @param current_length [Integer] current sequence length
    # @return [Result]
    def listen_more!(participant, trap, current_start, current_length)
      time_cost = Delve.action_time_seconds(:trap_listen) || Delve::ACTION_TIMES_SECONDS[:trap_listen]
      time_result = participant.spend_time_seconds!(time_cost)
      if time_result == :time_expired
        return Result.new(
          success: false,
          message: "Time runs out while you listen to the trap pattern!",
          data: { time_expired: true }
        )
      end

      # Extend sequence by configured amount
      new_length = current_length + GameConfig::DelveTrap::LISTEN_EXTEND_LENGTH
      sequence = trap.generate_sequence(current_start, new_length)

      Result.new(
        success: true,
        message: "You listen carefully to the trap's rhythm...\n\n#{format_sequence(sequence)}",
        data: {
          start_point: current_start,
          length: new_length,
          sequence: sequence
        }
      )
    end

    # Attempt to pass through the trap
    # @param participant [DelveParticipant] the participant
    # @param trap [DelveTrap] the trap
    # @param chosen_pulse [Integer] the pulse number the player chose (1-based display)
    # @param sequence_start [Integer] the actual tick of display pulse 1
    # @return [Result]
    def attempt_passage!(participant, trap, chosen_pulse, sequence_start)
      pulse = chosen_pulse.to_i
      unless pulse.positive?
        return Result.new(
          success: false,
          message: 'Invalid pulse number. Use a positive integer.',
          data: { invalid_pulse: true }
        )
      end

      if sequence_start.nil?
        return Result.new(
          success: false,
          message: 'Trap timing data is missing. Listen to the trap and try again.',
          data: { missing_sequence: true }
        )
      end

      # Convert display pulse to actual tick
      actual_tick = sequence_start + pulse - 1

      # Check if player has passed this trap before (makes it easier)
      experienced = participant.has_passed_trap?(trap.id)

      # Check if passage is safe
      # Experienced: only selected beat needs to be safe
      # First time: selected beat AND next beat must be safe
      safe = trap.safe_at?(actual_tick, experienced: experienced)

      # Mark trap as passed (for future easier passage)
      participant.mark_trap_passed!(trap.id)

      if safe
        Result.new(
          success: true,
          message: "You time your passage perfectly and slip through unharmed!",
          data: { safe: true, damage: 0, experienced: experienced }
        )
      else
        damage = trap.damage
        participant.take_hp_damage!(damage)
        trap.trigger!

        if participant.is_a?(DelveParticipant) && !participant.active?
          return Result.new(
            success: false,
            message: "#{trap_hit_message(trap)} You take #{damage} damage and collapse!",
            data: { safe: false, damage: damage, experienced: experienced, defeated: true }
          )
        end

        Result.new(
          success: true, # Still pass through, but take damage
          message: "#{trap_hit_message(trap)} You take #{damage} damage!",
          data: { safe: false, damage: damage, experienced: experienced }
        )
      end
    end

    # Attempt passage for all party members
    # @param participants [Array<DelveParticipant>] all party members
    # @param trap [DelveTrap] the trap
    # @param chosen_pulse [Integer] the pulse chosen by leader
    # @param sequence_start [Integer] the actual tick of display pulse 1
    # @return [Array<Hash>] per-participant passage outcomes
    def attempt_party_passage!(participants, trap, chosen_pulse, sequence_start)
      actual_tick = sequence_start + chosen_pulse - 1

      participants.map do |participant|
        experienced = participant.has_passed_trap?(trap.id)
        safe = trap.safe_at?(actual_tick, experienced: experienced)

        participant.mark_trap_passed!(trap.id)

        if safe
          { participant: participant, safe: true, damage: 0, experienced: experienced, defeated: false }
        else
          damage = trap.damage
          participant.take_hp_damage!(damage)
          trap.trigger!
          defeated = participant.respond_to?(:active?) && !participant.active?
          { participant: participant, safe: false, damage: damage, experienced: experienced, defeated: defeated }
        end
      end
    end

    private

    def format_sequence(sequence)
      items = sequence.map do |s|
        if s[:trapped]
          %(<li class="text-error font-bold">⚡ TRAP!</li>)
        else
          %(<li class="opacity-50">safe</li>)
        end
      end

      %(<ol class="my-2 space-y-0.5 pl-6">#{items.join}</ol>)
    end

    def trap_hit_message(trap)
      case trap.trap_theme
      when 'wall_crusher'
        "The walls slam together, crushing you between them!"
      when 'spikes'
        "Spikes thrust up from the floor, piercing your legs!"
      when 'pendulum_blade'
        "The massive blade catches you as it swings past!"
      when 'poison_dart'
        "Poison darts pepper you from hidden vents!"
      when 'steam_vent'
        "Scalding steam blasts you from the vents!"
      when 'gas_release'
        "Toxic gas burns your lungs!"
      when 'clockwork_blade'
        "Mechanical blades slice into you!"
      when 'laser_grid'
        "Lasers sear across your body!"
      when 'plasma_burst'
        "Plasma jets scorch you!"
      when 'disintegration_beam'
        "The disintegration beam grazes you!"
      else
        "The trap catches you!"
      end
    end
  end
end
