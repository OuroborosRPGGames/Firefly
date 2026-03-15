# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TimelineService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:spawn_room) do
    room = create(:room, location: location)
    GameSetting.set('tutorial_spawn_room_id', room.id, type: 'integer')
    room
  end
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive',
           level: 5,
           experience: 1000,
           health: 80,
           max_health: 100,
           mana: 40,
           max_mana: 50)
  end

  before do
    # Set primary instance for character
    allow(character).to receive(:primary_instance).and_return(character_instance)
  end

  describe 'error classes' do
    it 'defines TimelineError' do
      expect(described_class::TimelineError).to be < StandardError
    end

    it 'defines NotAllowedError' do
      expect(described_class::NotAllowedError).to be < described_class::TimelineError
    end
  end

  describe 'class methods' do
    it 'defines create_snapshot' do
      expect(described_class).to respond_to(:create_snapshot)
    end

    it 'defines enter_snapshot_timeline' do
      expect(described_class).to respond_to(:enter_snapshot_timeline)
    end

    it 'defines enter_historical_timeline' do
      expect(described_class).to respond_to(:enter_historical_timeline)
    end

    it 'defines leave_timeline' do
      expect(described_class).to respond_to(:leave_timeline)
    end

    it 'defines active_timelines_for' do
      expect(described_class).to respond_to(:active_timelines_for)
    end

    it 'defines snapshots_for' do
      expect(described_class).to respond_to(:snapshots_for)
    end

    it 'defines accessible_snapshots_for' do
      expect(described_class).to respond_to(:accessible_snapshots_for)
    end

    it 'defines delete_snapshot' do
      expect(described_class).to respond_to(:delete_snapshot)
    end

    it 'defines clone_inventory_to_timeline' do
      expect(described_class).to respond_to(:clone_inventory_to_timeline)
    end
  end

  describe '.create_snapshot' do
    before do
      allow_any_instance_of(Room).to receive(:characters_here).and_return(
        double(select_map: [character.id])
      )
    end

    it 'creates a snapshot via CharacterSnapshot.capture' do
      snapshot = described_class.create_snapshot(
        character_instance,
        name: 'Test Snapshot',
        description: 'A test'
      )

      expect(snapshot).to be_a(CharacterSnapshot)
      expect(snapshot.id).not_to be_nil
      expect(snapshot.name).to eq('Test Snapshot')
      expect(snapshot.description).to eq('A test')
    end

    it 'captures character state in the snapshot' do
      snapshot = described_class.create_snapshot(
        character_instance,
        name: 'State Snapshot'
      )

      expect(snapshot.character_id).to eq(character.id)
      expect(snapshot.room_id).to eq(room.id)
    end
  end

  describe '.enter_snapshot_timeline' do
    let(:snapshot) do
      CharacterSnapshot.create(
        character_id: character.id,
        room_id: room.id,
        name: 'Past Moment',
        frozen_state: Sequel.pg_jsonb_wrap({
          'level' => 3,
          'health' => 100,
          'max_health' => 100,
          'mana' => 50,
          'max_mana' => 50,
          'experience' => 500,
          'stats' => [],
          'abilities' => []
        }),
        allowed_character_ids: Sequel.pg_jsonb_wrap([character.id]),
        snapshot_taken_at: Time.now - 86400
      )
    end

    let(:timeline) do
      create(:timeline, snapshot_id: snapshot.id, reality: create(:reality))
    end

    before do
      allow(Timeline).to receive(:find_or_create_from_snapshot).and_return(timeline)
      allow(snapshot).to receive(:restore_to_instance)
    end

    context 'when character was present in snapshot' do
      it 'creates a new instance in the timeline' do
        instance = described_class.enter_snapshot_timeline(character, snapshot)

        expect(instance).to be_a(CharacterInstance)
        expect(instance.character_id).to eq(character.id)
        expect(instance.reality_id).to eq(timeline.reality_id)
        expect(instance.is_timeline_instance).to be true
      end

      it 'restores snapshot state to instance' do
        described_class.enter_snapshot_timeline(character, snapshot)

        expect(snapshot).to have_received(:restore_to_instance)
      end

      it 'uses snapshot room by default' do
        instance = described_class.enter_snapshot_timeline(character, snapshot)

        expect(instance.current_room_id).to eq(room.id)
      end

      it 'uses provided room when specified' do
        other_room = create(:room, location: location)
        instance = described_class.enter_snapshot_timeline(character, snapshot, room: other_room)

        expect(instance.current_room_id).to eq(other_room.id)
      end
    end

    context 'when character was not present in snapshot' do
      let(:other_character) { create(:character, forename: 'Bob') }

      it 'raises NotAllowedError' do
        expect {
          described_class.enter_snapshot_timeline(other_character, snapshot)
        }.to raise_error(TimelineService::NotAllowedError, /weren't present/)
      end
    end

    context 'when character already has instance in timeline' do
      let!(:existing_instance) do
        create(:character_instance,
               character: character,
               reality: timeline.reality,
               current_room: room,
               online: false)
      end

      it 'reactivates existing instance' do
        instance = described_class.enter_snapshot_timeline(character, snapshot)

        expect(instance.id).to eq(existing_instance.id)
        expect(instance.online).to be true
      end
    end
  end

  describe '.enter_historical_timeline' do
    let(:timeline) { create(:timeline, :historical, year: 1850, reality: create(:reality, :flashback)) }

    before do
      allow(Timeline).to receive(:find_or_create_historical).and_return(timeline)
    end

    it 'creates a new instance in the historical timeline' do
      instance = described_class.enter_historical_timeline(
        character,
        year: 1850,
        zone: area,
        room: room
      )

      expect(instance).to be_a(CharacterInstance)
      expect(instance.character_id).to eq(character.id)
      expect(instance.reality_id).to eq(timeline.reality_id)
      expect(instance.is_timeline_instance).to be true
    end

    it 'copies current character state' do
      instance = described_class.enter_historical_timeline(
        character,
        year: 1850,
        zone: area,
        room: room
      )

      # New instance should have copied stats from primary instance
      expect(instance.level).to eq(character_instance.level)
    end

    context 'when character already has instance in timeline' do
      let!(:existing_instance) do
        create(:character_instance,
               character: character,
               reality: timeline.reality,
               current_room: room,
               online: false)
      end

      it 'reactivates existing instance' do
        instance = described_class.enter_historical_timeline(
          character,
          year: 1850,
          zone: area,
          room: room
        )

        expect(instance.id).to eq(existing_instance.id)
        expect(instance.online).to be true
      end
    end
  end

  describe '.leave_timeline' do
    let(:timeline_reality) { create(:reality) }
    let(:timeline) { create(:timeline, reality: timeline_reality) }
    let(:timeline_instance) do
      create(:character_instance,
             character: character,
             reality: timeline_reality,
             current_room: room,
             online: true,
             is_timeline_instance: true,
             timeline_id: timeline.id)
    end

    before do
      allow(timeline_instance).to receive(:in_past_timeline?).and_return(true)
    end

    it 'sets instance offline' do
      result = described_class.leave_timeline(timeline_instance)

      expect(result).to be true
      timeline_instance.reload
      expect(timeline_instance.online).to be false
    end

    it 'clears following relationships' do
      following_instance = create(:character_instance)
      timeline_instance.update(following_id: following_instance.id)

      described_class.leave_timeline(timeline_instance)

      timeline_instance.reload
      expect(timeline_instance.following_id).to be_nil
    end

    context 'when instance is not in a past timeline' do
      before do
        allow(timeline_instance).to receive(:in_past_timeline?).and_return(false)
      end

      it 'returns false' do
        result = described_class.leave_timeline(timeline_instance)

        expect(result).to be false
      end
    end
  end

  describe '.active_timelines_for' do
    let(:timeline_reality) { create(:reality) }
    let!(:timeline_instance) do
      create(:character_instance,
             character: character,
             reality: timeline_reality,
             current_room: room,
             is_timeline_instance: true)
    end

    it 'returns timeline instances for the character' do
      instances = described_class.active_timelines_for(character)

      expect(instances).to include(timeline_instance)
    end

    it 'does not return non-timeline instances' do
      instances = described_class.active_timelines_for(character)

      # Primary instance is not a timeline instance
      expect(instances).not_to include(character_instance)
    end
  end

  describe '.snapshots_for' do
    let!(:snapshot1) do
      CharacterSnapshot.create(
        character_id: character.id,
        name: 'Snapshot 1',
        frozen_state: Sequel.pg_jsonb_wrap({ 'level' => 1 }),
        snapshot_taken_at: Time.now - 3600
      )
    end

    let!(:snapshot2) do
      CharacterSnapshot.create(
        character_id: character.id,
        name: 'Snapshot 2',
        frozen_state: Sequel.pg_jsonb_wrap({ 'level' => 1 }),
        snapshot_taken_at: Time.now
      )
    end

    it 'returns snapshots created by the character' do
      snapshots = described_class.snapshots_for(character)

      expect(snapshots.map(&:name)).to include('Snapshot 1', 'Snapshot 2')
    end

    it 'orders by snapshot_taken_at' do
      snapshots = described_class.snapshots_for(character)

      expect(snapshots.first.name).to eq('Snapshot 1')
      expect(snapshots.last.name).to eq('Snapshot 2')
    end
  end

  describe '.accessible_snapshots_for' do
    let(:other_character) { create(:character, forename: 'Bob') }

    let!(:accessible_snapshot) do
      CharacterSnapshot.create(
        character_id: other_character.id,
        name: 'Shared Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap({ 'level' => 1 }),
        allowed_character_ids: Sequel.pg_jsonb_wrap([character.id, other_character.id]),
        snapshot_taken_at: Time.now
      )
    end

    let!(:inaccessible_snapshot) do
      CharacterSnapshot.create(
        character_id: other_character.id,
        name: 'Private Snapshot',
        frozen_state: Sequel.pg_jsonb_wrap({ 'level' => 1 }),
        allowed_character_ids: Sequel.pg_jsonb_wrap([other_character.id]),
        snapshot_taken_at: Time.now
      )
    end

    it 'returns snapshots the character can access' do
      snapshots = described_class.accessible_snapshots_for(character)

      expect(snapshots.map(&:name)).to include('Shared Snapshot')
    end

    it 'does not return inaccessible snapshots' do
      snapshots = described_class.accessible_snapshots_for(character)

      expect(snapshots.map(&:name)).not_to include('Private Snapshot')
    end
  end

  describe '.delete_snapshot' do
    let(:snapshot) do
      CharacterSnapshot.create(
        character_id: character.id,
        name: 'To Delete',
        frozen_state: Sequel.pg_jsonb_wrap({ 'level' => 1 }),
        snapshot_taken_at: Time.now
      )
    end

    context 'when snapshot timeline is not in use' do
      before do
        allow(Timeline).to receive(:first).and_return(nil)
      end

      it 'deletes the snapshot' do
        result = described_class.delete_snapshot(snapshot)

        expect(result).to be true
        expect(CharacterSnapshot.first(id: snapshot.id)).to be_nil
      end
    end

    context 'when snapshot timeline is in use' do
      let(:timeline) { double('Timeline', in_use?: true) }

      before do
        allow(Timeline).to receive(:first).and_return(timeline)
      end

      it 'raises TimelineError' do
        expect {
          described_class.delete_snapshot(snapshot)
        }.to raise_error(TimelineService::TimelineError, /using its timeline/)
      end
    end
  end

  describe '.clone_inventory_to_timeline' do
    let(:timeline) { create(:timeline) }
    let(:target_instance) do
      create(:character_instance,
             character: character,
             reality: timeline.reality,
             current_room: room)
    end

    let(:pattern) { create(:pattern, name: 'Sword Pattern') }

    before do
      # Create source items
      Item.create(
        character_instance_id: character_instance.id,
        pattern_id: pattern.id,
        name: 'Iron Sword',
        description: 'A trusty blade',
        quantity: 1,
        condition: 'good',
        equipped: true,
        equipment_slot: 'main_hand'
      )

      Item.create(
        character_instance_id: character_instance.id,
        name: 'Health Potion',
        description: 'Heals wounds',
        quantity: 3,
        condition: 'excellent'
      )

      # Mock objects method
      allow(character_instance).to receive(:objects).and_return(
        Item.where(character_instance_id: character_instance.id).all
      )
    end

    it 'clones items from source to target instance' do
      described_class.clone_inventory_to_timeline(
        character_instance,
        target_instance,
        timeline
      )

      target_items = Item.where(character_instance_id: target_instance.id).all

      expect(target_items.count).to eq(2)
      expect(target_items.map(&:name)).to include('Iron Sword', 'Health Potion')
    end

    it 'tags cloned items with timeline_id' do
      described_class.clone_inventory_to_timeline(
        character_instance,
        target_instance,
        timeline
      )

      target_items = Item.where(character_instance_id: target_instance.id).all

      expect(target_items.all? { |item| item.timeline_id == timeline.id }).to be true
    end

    it 'preserves item attributes' do
      described_class.clone_inventory_to_timeline(
        character_instance,
        target_instance,
        timeline
      )

      cloned_sword = Item.first(
        character_instance_id: target_instance.id,
        name: 'Iron Sword'
      )

      expect(cloned_sword.equipped).to be true
      expect(cloned_sword.equipment_slot).to eq('main_hand')
      expect(cloned_sword.condition).to eq('good')
    end

    it 'handles nil source instance gracefully' do
      expect {
        described_class.clone_inventory_to_timeline(nil, target_instance, timeline)
      }.not_to raise_error
    end
  end

  describe 'private helpers' do
    describe '.copy_character_state_to_instance' do
      let(:target_instance) do
        create(:character_instance,
               character: character,
               reality: create(:reality, :flashback),
               current_room: room)
      end

      let(:stat) { create(:stat) }
      let(:ability) { create(:ability) }

      before do
        CharacterStat.create(
          character_instance_id: character_instance.id,
          stat_id: stat.id,
          base_value: 9
        )
        CharacterAbility.create(
          character_instance_id: character_instance.id,
          ability_id: ability.id,
          proficiency_level: 4
        )

        # Simulate existing rows already created during target instance setup.
        target_stat = CharacterStat.first(character_instance_id: target_instance.id, stat_id: stat.id)
        if target_stat
          target_stat.update(base_value: 2)
        else
          CharacterStat.create(
            character_instance_id: target_instance.id,
            stat_id: stat.id,
            base_value: 2
          )
        end

        target_ability = CharacterAbility.first(character_instance_id: target_instance.id, ability_id: ability.id)
        if target_ability
          target_ability.update(proficiency_level: 1)
        else
          CharacterAbility.create(
            character_instance_id: target_instance.id,
            ability_id: ability.id,
            proficiency_level: 1
          )
        end
      end

      it 'updates existing stat and ability rows instead of inserting duplicates' do
        described_class.send(:copy_character_state_to_instance, character, target_instance)

        copied_stat = CharacterStat.where(character_instance_id: target_instance.id, stat_id: stat.id).all
        copied_ability = CharacterAbility.where(character_instance_id: target_instance.id, ability_id: ability.id).all

        expect(copied_stat.length).to eq(1)
        expect(copied_ability.length).to eq(1)
        expect(copied_stat.first.base_value).to eq(9)
        expect(copied_ability.first.proficiency_level).to eq(4)
      end
    end
  end
end
