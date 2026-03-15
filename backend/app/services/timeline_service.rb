# frozen_string_literal: true

# TimelineService manages timeline operations:
# - Creating snapshots
# - Entering snapshot/historical timelines
# - Leaving timelines
# - Cloning inventory to timelines
class TimelineService
  class TimelineError < StandardError; end
  class NotAllowedError < TimelineError; end

  class << self
    # Create a snapshot of a character's current state
    # @param character_instance [CharacterInstance] The instance to snapshot
    # @param name [String] Name for the snapshot
    # @param description [String, nil] Optional description
    # @return [CharacterSnapshot] The created snapshot
    def create_snapshot(character_instance, name:, description: nil)
      CharacterSnapshot.capture(character_instance, name: name, description: description)
    end

    # Enter a snapshot timeline
    # @param character [Character] The character entering
    # @param snapshot [CharacterSnapshot] The snapshot to enter
    # @param room [Room, nil] Optional starting room (defaults to snapshot room)
    # @return [CharacterInstance] The new timeline instance
    def enter_snapshot_timeline(character, snapshot, room: nil)
      unless snapshot.can_enter?(character)
        raise NotAllowedError, "You weren't present when this snapshot was created"
      end

      timeline = Timeline.find_or_create_from_snapshot(snapshot)
      starting_room = room || snapshot.room || find_starting_room

      # Check if character already has an instance in this timeline
      existing = CharacterInstance.first(
        character_id: character.id,
        reality_id: timeline.reality_id
      )

      if existing
        # Reactivate existing instance and position in room
        existing.update(online: true)
        existing.teleport_to_room!(starting_room)
        return existing
      end

      # Create new instance in the timeline
      instance = create_timeline_instance(character, timeline, starting_room)

      # Restore snapshot state to instance
      snapshot.restore_to_instance(instance)

      # Clone current inventory to timeline
      clone_inventory_to_timeline(character.primary_instance, instance, timeline)

      instance
    end

    # Enter a historical timeline (year + zone required)
    # @param character [Character] The character entering
    # @param year [Integer] The historical year
    # @param zone [Zone] The zone for the timeline
    # @param room [Room, nil] Optional starting room (defaults to room in zone)
    # @return [CharacterInstance] The new timeline instance
    def enter_historical_timeline(character, year:, zone:, room: nil)
      timeline = Timeline.find_or_create_historical(year: year, zone: zone, created_by: character)
      starting_room = room || find_room_in_zone(zone) || find_starting_room

      # Check if character already has an instance in this timeline
      existing = CharacterInstance.first(
        character_id: character.id,
        reality_id: timeline.reality_id
      )

      if existing
        # Reactivate existing instance and position in room
        existing.update(online: true)
        existing.teleport_to_room!(starting_room)
        return existing
      end

      # Create new instance in the timeline
      instance = create_timeline_instance(character, timeline, starting_room)

      # Copy current character state (not a snapshot restore)
      copy_character_state_to_instance(character, instance)

      # Clone current inventory to timeline
      clone_inventory_to_timeline(character.primary_instance, instance, timeline)

      instance
    end

    # Leave a timeline (go offline in that timeline)
    # @param character_instance [CharacterInstance] The instance to take offline
    # @return [Boolean] Whether the operation succeeded
    def leave_timeline(character_instance)
      return false unless character_instance.in_past_timeline?

      character_instance.update(
        online: false,
        following_id: nil,
        observing_id: nil,
        reading_mind_id: nil
      )

      true
    end

    # Get all active timeline instances for a character
    # @param character [Character] The character
    # @return [Array<CharacterInstance>] Timeline instances
    def active_timelines_for(character)
      CharacterInstance
        .where(character_id: character.id, is_timeline_instance: true)
        .eager(:reality)
        .all
    end

    # Get all snapshots created by a character
    # @param character [Character] The character
    # @return [Array<CharacterSnapshot>] Snapshots
    def snapshots_for(character)
      CharacterSnapshot.where(character_id: character.id).order(:snapshot_taken_at).all
    end

    # Get all snapshots a character can access
    # @param character [Character] The character
    # @return [Array<CharacterSnapshot>] Accessible snapshots
    def accessible_snapshots_for(character)
      # Use PostgreSQL JSONB containment to check if character_id is in allowed_character_ids
      CharacterSnapshot.where(
        Sequel.lit("allowed_character_ids @> ?::jsonb", [character.id].to_json)
      ).all
    end

    # Delete a snapshot (if not in use)
    # @param snapshot [CharacterSnapshot] The snapshot to delete
    # @return [Boolean] Whether deletion succeeded
    def delete_snapshot(snapshot)
      # Check if anyone is using this snapshot's timeline
      timeline = Timeline.first(snapshot_id: snapshot.id)
      if timeline&.in_use?
        raise TimelineError, "Cannot delete snapshot while someone is using its timeline"
      end

      # Deactivate the timeline if it exists
      timeline&.deactivate!

      # Delete the snapshot
      snapshot.destroy
      true
    end

    # Clone inventory from one instance to another with timeline tags
    # @param source_instance [CharacterInstance] Source inventory
    # @param target_instance [CharacterInstance] Target to receive cloned items
    # @param timeline [Timeline] Timeline to tag items with
    def clone_inventory_to_timeline(source_instance, target_instance, timeline)
      return unless source_instance

      source_instance.objects.each do |item|
        Item.create(
          character_instance_id: target_instance.id,
          pattern_id: item.pattern_id,
          name: item.name,
          description: item.description,
          image_url: item.image_url,
          thumbnail_url: item.thumbnail_url,
          quantity: item.quantity || 1,
          condition: item.condition || 'good',
          equipped: item.equipped || false,
          equipment_slot: item.equipment_slot,
          worn: item.worn || false,
          worn_layer: item.worn_layer,
          held: item.held || false,
          stored: item.stored || false,
          concealed: item.concealed || false,
          zipped: item.zipped || false,
          torn: item.torn || 0,
          display_order: item.display_order || 0,
          timeline_id: timeline.id  # Tag with timeline!
        )
      end
    end

    private

    def create_timeline_instance(character, timeline, room)
      CharacterInstance.create(
        character_id: character.id,
        reality_id: timeline.reality_id,
        current_room_id: room.id,
        is_timeline_instance: true,
        timeline_id: timeline.id,
        source_snapshot_id: timeline.snapshot_id,
        online: true,
        status: 'alive',
        stance: 'standing',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    def copy_character_state_to_instance(character, instance)
      primary = character.primary_instance
      return unless primary

      instance.update(
        level: primary.level,
        experience: primary.experience,
        health: primary.max_health,  # Start at full health
        max_health: primary.max_health,
        mana: primary.max_mana,  # Start at full mana
        max_mana: primary.max_mana
      )

      # Copy stats
      primary.character_stats.each do |stat|
        existing_stat = CharacterStat.first(
          character_instance_id: instance.id,
          stat_id: stat.stat_id
        )

        if existing_stat
          existing_stat.update(base_value: stat.base_value)
        else
          CharacterStat.create(
            character_instance_id: instance.id,
            stat_id: stat.stat_id,
            base_value: stat.base_value
          )
        end
      end

      # Copy abilities
      primary.character_abilities.each do |ability|
        ca = CharacterAbility.first(
          character_instance_id: instance.id,
          ability_id: ability.ability_id
        )

        unless ca
          ca = CharacterAbility.create(
            character_instance_id: instance.id,
            ability_id: ability.ability_id
          )
        end

        ca.update(proficiency_level: ability.proficiency_level) if ability.respond_to?(:proficiency_level) && ca.respond_to?(:proficiency_level=)
      end
    end

    def find_starting_room
      Room.tutorial_spawn_room
    end

    def find_room_in_zone(zone)
      return nil unless zone

      # Find a room in a location within this zone
      location_ids = Location.where(zone_id: zone.id).select_map(:id)
      return nil if location_ids.empty?

      Room.where(location_id: location_ids).first
    end
  end
end
