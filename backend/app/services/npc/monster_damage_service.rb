# frozen_string_literal: true

# Handles damage to monster segments and weak point mechanics.
# Manages segment status updates, collapse, and defeat conditions.
class MonsterDamageService
  def initialize(monster_instance)
    @monster = monster_instance
    @template = monster_instance.monster_template
  end

  # Apply damage to a specific segment
  # @param segment [MonsterSegmentInstance]
  # @param damage [Integer]
  # @return [Hash] { segment_damage: Integer, total_damage: Integer, segment_status: String, events: Array }
  def apply_damage_to_segment(segment, damage)
    events = []

    # Apply damage to segment
    result = segment.apply_damage!(damage)

    # Apply to monster's total HP
    @monster.apply_damage!(damage)

    # Check for segment destruction
    if result[:new_status] == 'destroyed'
      events << {
        type: 'segment_destroyed',
        segment_name: segment.name,
        segment_type: segment.segment_type
      }

      # Check for collapse if mobility segment
      if segment.required_for_mobility?
        collapse_result = check_collapse_condition
        events.concat(collapse_result[:events]) if collapse_result[:collapsed]
      end
    end

    # Check for monster defeat
    if @monster.defeated?
      events << { type: 'monster_defeated', monster_name: @monster.display_name }
    end

    {
      segment_damage: result[:segment_hp_lost],
      total_damage: damage,
      segment_status: result[:new_status],
      monster_hp: @monster.current_hp,
      monster_hp_percent: @monster.current_hp_percent,
      events: events
    }
  end

  # Apply weak point attack (triple damage distributed to all segments)
  # @param base_damage [Integer] the base damage before tripling
  # @param attacker [FightParticipant]
  # @return [Hash] { total_damage: Integer, damage_per_segment: Hash, events: Array }
  def apply_weak_point_attack(base_damage, attacker)
    events = []
    total_damage = base_damage * 3
    active_segments = @monster.active_segments

    return { total_damage: 0, damage_per_segment: {}, events: [] } if active_segments.empty?

    # Distribute damage evenly across all active segments
    damage_per_segment = (total_damage.to_f / active_segments.count).ceil
    segment_results = {}

    active_segments.each do |segment|
      result = apply_damage_to_segment(segment, damage_per_segment)
      segment_results[segment.name] = {
        damage: damage_per_segment,
        new_status: result[:segment_status]
      }
      events.concat(result[:events])
    end

    # Fling the attacker clear
    fling_result = fling_attacker(attacker)
    events << {
      type: 'weak_point_attack',
      attacker_name: attacker.character_name,
      base_damage: base_damage,
      total_damage: total_damage,
      segments_hit: active_segments.count
    }
    events << fling_result[:event] if fling_result[:event]

    {
      total_damage: total_damage,
      damage_per_segment: segment_results,
      scatter_position: fling_result[:position],
      events: events
    }
  end

  # Check if collapse should be triggered (enough mobility segments destroyed)
  # @return [Hash] { collapsed: Boolean, events: Array }
  def check_collapse_condition
    return { collapsed: false, events: [] } if @monster.collapsed?

    mobility_segments = @monster.monster_segment_instances.select(&:required_for_mobility?)
    return { collapsed: false, events: [] } if mobility_segments.empty?

    destroyed_count = mobility_segments.count { |s| s.status == 'destroyed' }
    threshold = (mobility_segments.count / 2.0).ceil

    if destroyed_count >= threshold
      trigger_collapse
      {
        collapsed: true,
        events: [{
          type: 'monster_collapsed',
          monster_name: @monster.display_name,
          destroyed_segments: destroyed_count,
          total_mobility_segments: mobility_segments.count
        }]
      }
    else
      { collapsed: false, events: [] }
    end
  end

  # Trigger monster collapse
  # All mounted players are safely dismounted
  def trigger_collapse
    @monster.collapse!

    # Dismount all players safely (they slide off the collapsing creature)
    hex_service = MonsterHexService.new(@monster)

    @monster.monster_mount_states.each do |mount_state|
      next if mount_state.mount_status == 'dismounted'

      scatter_pos = hex_service.calculate_scatter_position
      mount_state.dismount!(scatter_pos[0], scatter_pos[1])
    end
  end

  # Check if monster should be defeated
  # @return [Boolean]
  def check_monster_defeat
    @monster.defeated?
  end

  # Update segment status based on current HP
  # @param segment [MonsterSegmentInstance]
  def update_segment_status(segment)
    segment.update_status_from_hp!
  end

  private

  # Fling the attacker after a weak point attack
  # @param attacker [FightParticipant]
  # @return [Hash] { position: [x, y], event: Hash }
  def fling_attacker(attacker)
    mount_state = MonsterMountState.first(
      large_monster_instance_id: @monster.id,
      fight_participant_id: attacker.id
    )

    return { position: nil, event: nil } unless mount_state

    hex_service = MonsterHexService.new(@monster)
    scatter_pos = hex_service.calculate_scatter_position

    mount_state.fling_after_weak_point_attack!(scatter_pos[0], scatter_pos[1])

    # Check for hazard landing
    hazard = hex_service.check_hazard_at(scatter_pos[0], scatter_pos[1])

    event = {
      type: 'attacker_flung',
      attacker_name: attacker.character_name,
      landing_x: scatter_pos[0],
      landing_y: scatter_pos[1],
      landed_in_hazard: !hazard.nil?,
      hazard_type: hazard&.hazard_type
    }

    { position: scatter_pos, event: event }
  end
end
