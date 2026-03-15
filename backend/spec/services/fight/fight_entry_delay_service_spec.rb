# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightEntryDelayService do
  let(:location) { create(:location) }
  # fight_room: default bounds 0-100
  let(:fight_room) { create(:room, location: location, min_y: 0.0, max_y: 100.0) }
  # nearby_room: north of fight_room (shares edge at y=100)
  let(:nearby_room) { create(:room, location: location, min_y: 100.0, max_y: 200.0) }
  # distant_room: north of nearby_room (2 rooms away from fight_room)
  let(:distant_room) { create(:room, location: location, min_y: 200.0, max_y: 300.0) }
  let(:fight) { Fight.create(room_id: fight_room.id) }

  describe '.snapshot_distances' do
    it 'creates delay records for all online characters' do
      char_in_fight = create(:character_instance, current_room: fight_room, online: true, x: 50.0, y: 50.0, z: 0.0)
      char_nearby = create(:character_instance, current_room: nearby_room, online: true, x: 50.0, y: 50.0, z: 0.0)
      char_offline = create(:character_instance, current_room: nearby_room, online: false)

      described_class.snapshot_distances(fight)

      # Should have records for online characters only
      expect(FightEntryDelay.where(fight_id: fight.id).count).to eq(2)
      expect(FightEntryDelay.where(character_instance_id: char_offline.id).count).to eq(0)
    end

    it 'marks characters in fight room with in_fight_room: true' do
      char_in_fight = create(:character_instance, current_room: fight_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      described_class.snapshot_distances(fight)

      delay = FightEntryDelay.where(character_instance_id: char_in_fight.id).first
      expect(delay.in_fight_room).to be true
      expect(delay.distance_at_start).to eq(0.0)
      expect(delay.delay_rounds).to eq(0)
    end

    it 'calculates distance for characters in other rooms' do
      char_nearby = create(:character_instance, current_room: nearby_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      described_class.snapshot_distances(fight)

      delay = FightEntryDelay.where(character_instance_id: char_nearby.id).first
      expect(delay.in_fight_room).to be false
      expect(delay.distance_at_start).to be > 0
    end

    it 'sets entry_allowed_at_round based on distance' do
      char = create(:character_instance, current_room: nearby_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      described_class.snapshot_distances(fight)

      delay = FightEntryDelay.where(character_instance_id: char.id).first
      expect(delay.entry_allowed_at_round).to eq(fight.round_number + delay.delay_rounds)
    end
  end

  describe '.can_enter?' do
    it 'returns true for character in fight room' do
      char = create(:character_instance, current_room: fight_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 0.0,
        delay_rounds: 0,
        entry_allowed_at_round: 1,
        in_fight_room: true
      )

      expect(described_class.can_enter?(char, fight)).to be true
    end

    it 'returns false for distant character before delay expires' do
      char = create(:character_instance, current_room: distant_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 100.0,
        delay_rounds: 4,
        entry_allowed_at_round: 5,
        in_fight_room: false
      )

      expect(described_class.can_enter?(char, fight)).to be false
    end

    it 'returns true for distant character after delay expires' do
      char = create(:character_instance, current_room: distant_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 50.0,
        delay_rounds: 2,
        entry_allowed_at_round: 3,
        in_fight_room: false
      )

      fight.update(round_number: 3)

      expect(described_class.can_enter?(char, fight)).to be true
    end

    it 'creates delay record for character without one' do
      char = create(:character_instance, current_room: nearby_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      # No pre-existing delay record
      expect(FightEntryDelay.where(character_instance_id: char.id).count).to eq(0)

      # Calling can_enter? should create one
      described_class.can_enter?(char, fight)

      expect(FightEntryDelay.where(character_instance_id: char.id).count).to eq(1)
    end
  end

  describe '.rounds_until_entry' do
    it 'returns 0 for character who can enter' do
      char = create(:character_instance, current_room: fight_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 0.0,
        delay_rounds: 0,
        entry_allowed_at_round: 1,
        in_fight_room: true
      )

      expect(described_class.rounds_until_entry(char, fight)).to eq(0)
    end

    it 'returns correct count for blocked character' do
      char = create(:character_instance, current_room: distant_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 75.0,
        delay_rounds: 3,
        entry_allowed_at_round: 4,
        in_fight_room: false
      )

      expect(described_class.rounds_until_entry(char, fight)).to eq(3)
    end

    it 'decrements as fight rounds advance' do
      char = create(:character_instance, current_room: distant_room, online: true, x: 50.0, y: 50.0, z: 0.0)

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: char.id,
        distance_at_start: 50.0,
        delay_rounds: 2,
        entry_allowed_at_round: 3,
        in_fight_room: false
      )

      expect(described_class.rounds_until_entry(char, fight)).to eq(2)

      fight.update(round_number: 2)
      expect(described_class.rounds_until_entry(char, fight)).to eq(1)

      fight.update(round_number: 3)
      expect(described_class.rounds_until_entry(char, fight)).to eq(0)
    end
  end

  describe '.create_delays_for_character' do
    it 'creates delay records for all active fights' do
      # Create active fights
      fight1 = Fight.create(room_id: fight_room.id, status: 'input')
      fight2 = Fight.create(room_id: nearby_room.id, status: 'resolving')

      # Character logs in
      char = create(:character_instance, current_room: distant_room, online: false, x: 50.0, y: 50.0, z: 0.0)

      described_class.create_delays_for_character(char)

      expect(FightEntryDelay.where(character_instance_id: char.id).count).to eq(2)
    end

    it 'skips completed fights' do
      active_fight = Fight.create(room_id: fight_room.id, status: 'input')
      completed_fight = Fight.create(room_id: nearby_room.id, status: 'complete')

      char = create(:character_instance, current_room: distant_room, online: false, x: 50.0, y: 50.0, z: 0.0)

      described_class.create_delays_for_character(char)

      expect(FightEntryDelay.where(character_instance_id: char.id, fight_id: active_fight.id).count).to eq(1)
      expect(FightEntryDelay.where(character_instance_id: char.id, fight_id: completed_fight.id).count).to eq(0)
    end

    it 'does not duplicate existing delay records' do
      active_fight = Fight.create(room_id: fight_room.id, status: 'input')
      char = create(:character_instance, current_room: distant_room, online: false, x: 50.0, y: 50.0, z: 0.0)

      # Create existing delay record
      FightEntryDelay.create(
        fight_id: active_fight.id,
        character_instance_id: char.id,
        distance_at_start: 100.0,
        delay_rounds: 4,
        entry_allowed_at_round: 5,
        in_fight_room: false
      )

      # Calling create_delays_for_character should not create a duplicate
      described_class.create_delays_for_character(char)

      expect(FightEntryDelay.where(character_instance_id: char.id).count).to eq(1)
    end

    it 'does nothing when no active fights exist' do
      char = create(:character_instance, current_room: distant_room, online: false, x: 50.0, y: 50.0, z: 0.0)

      described_class.create_delays_for_character(char)

      expect(FightEntryDelay.where(character_instance_id: char.id).count).to eq(0)
    end

    it 'calculates delay based on current round number' do
      # Fight already at round 3
      active_fight = Fight.create(room_id: fight_room.id, status: 'input', round_number: 3)

      char = create(:character_instance, current_room: distant_room, online: false, x: 50.0, y: 50.0, z: 0.0)

      described_class.create_delays_for_character(char)

      delay = FightEntryDelay.where(character_instance_id: char.id).first
      # Entry round should be based on current round (3) + delay_rounds
      expect(delay.entry_allowed_at_round).to eq(3 + delay.delay_rounds)
    end
  end
end
