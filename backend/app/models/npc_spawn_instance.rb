# frozen_string_literal: true

# Tracks active NPC instances spawned by schedule or manual placement
class NpcSpawnInstance < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :character_instance
  many_to_one :npc_schedule
  many_to_one :room

  def validate
    super
    validates_presence [:character_id, :character_instance_id, :room_id, :spawned_at]
  end

  def before_save
    super
    self.spawned_at ||= Time.now
  end

  # Check if this spawn should be despawned
  def should_despawn?(current_time = Time.now)
    return true unless active
    return true if despawn_at && current_time >= despawn_at

    # If tied to a schedule, check if schedule still applies
    if npc_schedule
      !npc_schedule.applies_now?(current_time)
    else
      false
    end
  end

  # Despawn this NPC instance
  def despawn!
    return unless active

    # Mark spawn as inactive
    update(active: false)

    # Keep NPC online if another active spawn still references this instance.
    has_other_active_spawns = NpcSpawnInstance
      .where(character_instance_id: character_instance_id, active: true)
      .exclude(id: id)
      .any?
    character_instance&.update(online: false) unless has_other_active_spawns

    # Update schedule tracking
    if npc_schedule_id
      schedule_still_active = NpcSpawnInstance
        .where(npc_schedule_id: npc_schedule_id, active: true)
        .exclude(id: id)
        .any?
      npc_schedule&.update(current: false) unless schedule_still_active
    end
  end

  # Class methods
  class << self
    def active_spawns
      where(active: true)
    end

    def for_room(room_id)
      where(room_id: room_id, active: true)
    end

    def for_character(character_id)
      where(character_id: character_id, active: true)
    end

    def for_schedule(schedule_id)
      where(npc_schedule_id: schedule_id, active: true)
    end

    def due_for_despawn(current_time = Time.now)
      active_spawns.all.select { |s| s.should_despawn?(current_time) }
    end
  end
end
