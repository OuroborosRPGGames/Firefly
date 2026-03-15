# frozen_string_literal: true

# Tracks a player mounted on a monster.
# Manages climb progress, mount status, and shake-off scatter.
class MonsterMountState < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :large_monster_instance, class: :LargeMonsterInstance, key: :large_monster_instance_id
  many_to_one :fight_participant
  many_to_one :current_segment, class: :MonsterSegmentInstance, key: :current_segment_id

  status_enum :mount_status, %w[mounted climbing at_weak_point thrown dismounted]

  def validate
    super
    validates_presence [:large_monster_instance_id, :fight_participant_id, :climb_progress]
    validate_mount_status_enum
  end

  def before_create
    super
    self.climb_progress ||= 0
    self.mount_status ||= 'mounted'
    self.mounted_at ||= Time.now
  end

  # Get the climb distance required to reach the weak point
  # @return [Integer]
  def climb_distance
    large_monster_instance.monster_template.climb_distance
  end

  # Check if player has reached the weak point
  # @return [Boolean]
  def at_weak_point?
    mount_status == 'at_weak_point' || climb_progress >= climb_distance
  end

  # Advance climb progress by one step
  # @return [Hash] { progress: Integer, reached_weak_point: Boolean }
  def advance_climb!
    new_progress = climb_progress + 1

    if new_progress >= climb_distance
      update(climb_progress: new_progress, mount_status: 'at_weak_point')
      { progress: new_progress, reached_weak_point: true }
    else
      update(climb_progress: new_progress, mount_status: 'climbing')
      { progress: new_progress, reached_weak_point: false }
    end
  end

  # Set to cling mode (safe from shake-off)
  def set_cling!
    update(mount_status: 'mounted')  # 'mounted' = clinging/safe
    fight_participant.update(mount_action: 'cling')
  end

  # Set to climbing mode (vulnerable to shake-off)
  def set_climbing!
    update(mount_status: 'climbing')
    fight_participant.update(mount_action: 'climb')
  end

  # Check if the mount action for this round is 'cling' (safe from shake-off)
  # @return [Boolean]
  def mount_action_is_cling?
    fight_participant.mount_action == 'cling'
  end

  # Throw off this mounted player
  # @param scatter_x [Integer] landing hex x
  # @param scatter_y [Integer] landing hex y
  def throw_off!(scatter_x, scatter_y)
    update(
      mount_status: 'thrown',
      climb_progress: 0,
      scatter_hex_x: scatter_x,
      scatter_hex_y: scatter_y
    )

    # Update participant state
    fight_participant.update(is_mounted: false, mount_action: nil)
  end

  # Safely dismount the player
  # @param hex_x [Integer] landing hex x
  # @param hex_y [Integer] landing hex y
  def dismount!(hex_x, hex_y)
    update(
      mount_status: 'dismounted',
      scatter_hex_x: hex_x,
      scatter_hex_y: hex_y
    )

    # Update participant position and state
    fight_participant.update(
      is_mounted: false,
      mount_action: nil,
      hex_x: hex_x,
      hex_y: hex_y
    )
  end

  # Apply throw and position the participant at scatter location
  def apply_throw!
    return unless mount_status == 'thrown' && scatter_hex_x && scatter_hex_y

    fight_participant.update(
      hex_x: scatter_hex_x,
      hex_y: scatter_hex_y
    )

    update(mount_status: 'dismounted')
  end

  # Reset after weak point attack (player is flung clear)
  # @param scatter_x [Integer]
  # @param scatter_y [Integer]
  def fling_after_weak_point_attack!(scatter_x, scatter_y)
    update(
      mount_status: 'dismounted',
      climb_progress: 0,
      scatter_hex_x: scatter_x,
      scatter_hex_y: scatter_y
    )

    fight_participant.update(
      is_mounted: false,
      mount_action: nil,
      hex_x: scatter_x,
      hex_y: scatter_y
    )
  end

  # Get display info for UI
  # @return [Hash]
  def display_info
    {
      participant_name: fight_participant.character_name,
      monster_name: large_monster_instance.display_name,
      climb_progress: climb_progress,
      climb_distance: climb_distance,
      at_weak_point: at_weak_point?,
      mount_status: mount_status,
      current_segment: current_segment&.name
    }
  end
end
