# frozen_string_literal: true

# Handles mount/climb/cling/dismount mechanics for monster combat.
class MonsterMountingService
  def initialize(fight)
    @fight = fight
  end

  # Attempt to mount a monster
  # @param participant [FightParticipant]
  # @param monster [LargeMonsterInstance]
  # @return [Hash] { success: Boolean, mount_state: MonsterMountState, error: String }
  def attempt_mount(participant, monster)
    # Check if already mounted
    if participant.is_mounted
      return { success: false, error: 'Already mounted on a monster' }
    end

    # Check if adjacent to monster
    hex_service = MonsterHexService.new(monster)
    unless hex_service.adjacent_to_monster?(participant)
      return { success: false, error: 'Must be adjacent to the monster to mount' }
    end

    # Find the closest segment to mount onto
    closest_segment = monster.closest_segment_to(participant.hex_x, participant.hex_y)

    # Create mount state
    mount_state = MonsterMountState.create(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id,
      current_segment_id: closest_segment&.id,
      climb_progress: 0,
      mount_status: 'mounted',
      mounted_at: Time.now
    )

    # Update participant state
    participant.update(
      is_mounted: true,
      mount_action: 'cling',  # Default to clinging (safe)
      targeting_monster_id: monster.id,
      targeting_segment_id: closest_segment&.id
    )

    {
      success: true,
      mount_state: mount_state,
      segment: closest_segment
    }
  end

  # Process climb action (progress toward weak point)
  # @param mount_state [MonsterMountState]
  # @return [Hash] { success: Boolean, progress: Integer, at_weak_point: Boolean }
  def process_climb(mount_state)
    mount_state.set_climbing!
    result = mount_state.advance_climb!

    # If reached weak point, update segment targeting to weak point
    if result[:reached_weak_point]
      weak_point = mount_state.large_monster_instance.weak_point_segment
      if weak_point
        mount_state.update(current_segment_id: weak_point.id)
        mount_state.fight_participant.update(targeting_segment_id: weak_point.id)
      end
    end

    {
      success: true,
      progress: result[:progress],
      climb_distance: mount_state.climb_distance,
      at_weak_point: result[:reached_weak_point]
    }
  end

  # Process cling action (hold position, safe from shake-off)
  # @param mount_state [MonsterMountState]
  # @return [Hash] { success: Boolean }
  def process_cling(mount_state)
    mount_state.set_cling!
    { success: true, status: 'clinging' }
  end

  # Process dismount action (safely get off)
  # @param mount_state [MonsterMountState]
  # @return [Hash] { success: Boolean, landing_position: [x, y] }
  def process_dismount(mount_state)
    hex_service = MonsterHexService.new(mount_state.large_monster_instance)

    # Find a safe adjacent hex
    participant = mount_state.fight_participant
    landing_hex = hex_service.closest_mounting_hex(
      mount_state.large_monster_instance.center_hex_x,
      mount_state.large_monster_instance.center_hex_y
    )

    # If no adjacent hex found, use scatter position
    landing_hex ||= hex_service.calculate_scatter_position

    mount_state.dismount!(landing_hex[0], landing_hex[1])

    {
      success: true,
      landing_position: landing_hex
    }
  end

  # Process shake-off action by monster
  # Throws off all non-clinging players
  # @param monster [LargeMonsterInstance]
  # @return [Hash] { thrown_count: Integer, results: Array }
  def process_shake_off(monster)
    hex_service = MonsterHexService.new(monster)
    results = []

    monster.monster_mount_states.each do |mount_state|
      next if mount_state.mount_status == 'dismounted'

      participant = mount_state.fight_participant

      if mount_state.mount_action_is_cling?
        # Safe! Player held on
        results << {
          participant_name: participant.character_name,
          thrown: false,
          reason: 'clinging'
        }
      else
        # Thrown off!
        scatter_pos = hex_service.calculate_scatter_position
        mount_state.throw_off!(scatter_pos[0], scatter_pos[1])

        # Check for hazard landing
        hazard = hex_service.check_hazard_at(scatter_pos[0], scatter_pos[1])

        results << {
          participant_name: participant.character_name,
          thrown: true,
          landing_x: scatter_pos[0],
          landing_y: scatter_pos[1],
          landed_in_hazard: !hazard.nil?,
          hazard_type: hazard&.hazard_type
        }
      end
    end

    {
      thrown_count: results.count { |r| r[:thrown] },
      results: results
    }
  end

  # Get the segment a mounted participant should target
  # @param participant [FightParticipant]
  # @param monster [LargeMonsterInstance]
  # @return [MonsterSegmentInstance, nil]
  def target_segment(participant, monster)
    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )

    if mount_state&.current_segment
      # Return the segment they're on
      mount_state.current_segment
    else
      # Return geometrically closest segment
      monster.closest_segment_to(participant.hex_x, participant.hex_y)
    end
  end

  # Check if participant is at the weak point
  # @param participant [FightParticipant]
  # @param monster [LargeMonsterInstance]
  # @return [Boolean]
  def at_weak_point?(participant, monster)
    mount_state = MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )

    mount_state&.at_weak_point? || false
  end

  # Get mount state for a participant on a monster
  # @param participant [FightParticipant]
  # @param monster [LargeMonsterInstance]
  # @return [MonsterMountState, nil]
  def mount_state(participant, monster)
    MonsterMountState.first(
      large_monster_instance_id: monster.id,
      fight_participant_id: participant.id
    )
  end

  # Get all mount states for a monster
  # @param monster [LargeMonsterInstance]
  # @return [Array<MonsterMountState>]
  def all_mount_states(monster)
    monster.monster_mount_states.reject { |ms| ms.mount_status == 'dismounted' }
  end

  # Apply all thrown mount states (position participants at scatter locations)
  # Called after shake-off resolution
  # @param monster [LargeMonsterInstance]
  def apply_thrown_positions(monster)
    monster.monster_mount_states.each do |mount_state|
      mount_state.apply_throw! if mount_state.mount_status == 'thrown'
    end
  end
end
