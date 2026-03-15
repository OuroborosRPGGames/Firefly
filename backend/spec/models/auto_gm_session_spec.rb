# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGmSession do
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  describe 'validations' do
    it 'requires starting_room_id' do
      session = AutoGmSession.new(status: 'gathering')
      expect(session.valid?).to be false
      expect(session.errors[:starting_room_id]).not_to be_empty
    end

    it 'requires status' do
      session = AutoGmSession.new(starting_room_id: room.id)
      session.status = nil
      expect(session.valid?).to be false
      expect(session.errors[:status]).not_to be_empty
    end

    it 'validates status is in allowed list' do
      session = AutoGmSession.new(starting_room_id: room.id, status: 'invalid')
      expect(session.valid?).to be false
    end

    it 'validates resolution_type when present' do
      session = AutoGmSession.new(starting_room_id: room.id, status: 'resolved', resolution_type: 'invalid')
      expect(session.valid?).to be false
    end
  end

  describe 'defaults' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }

    it 'sets default chaos_level to 5' do
      expect(session.chaos_level).to eq(5)
    end

    it 'sets default current_stage to 0' do
      expect(session.current_stage).to eq(0)
    end

    it 'sets current_room_id to starting_room_id' do
      expect(session.current_room_id).to eq(room.id)
    end

    it 'initializes participant_ids as empty array' do
      expect(session.participant_ids.to_a).to eq([])
    end
  end

  describe 'status methods' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }

    describe '#gathering?' do
      it 'returns true when status is gathering' do
        expect(session.gathering?).to be true
      end
    end

    describe '#running?' do
      it 'returns true when status is running' do
        session.update(status: 'running')
        expect(session.running?).to be true
      end
    end

    describe '#in_combat?' do
      it 'returns true when status is combat' do
        session.update(status: 'combat')
        expect(session.in_combat?).to be true
      end
    end

    describe '#resolved?' do
      it 'returns true when status is resolved' do
        session.update(status: 'resolved')
        expect(session.resolved?).to be true
      end
    end

    describe '#active?' do
      it 'returns true for active statuses' do
        %w[gathering sketching inciting running combat climax].each do |status|
          session.update(status: status)
          expect(session.active?).to be true
        end
      end

      it 'returns false for inactive statuses' do
        %w[resolved abandoned].each do |status|
          session.update(status: status)
          expect(session.active?).to be false
        end
      end
    end

    describe '#gm_can_act?' do
      it 'returns true for running' do
        session.update(status: 'running')
        expect(session.gm_can_act?).to be true
      end

      it 'returns true for climax' do
        session.update(status: 'climax')
        expect(session.gm_can_act?).to be true
      end

      it 'returns false for other statuses' do
        session.update(status: 'gathering')
        expect(session.gm_can_act?).to be false
      end
    end
  end

  describe 'participant management' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }

    describe '#add_participant!' do
      it 'adds character instance to participants' do
        session.add_participant!(character_instance)
        expect(session.participant_ids.to_a).to include(character_instance.id)
      end

      it 'does not add duplicates' do
        session.add_participant!(character_instance)
        session.add_participant!(character_instance)
        expect(session.participant_ids.to_a.count { |id| id == character_instance.id }).to eq(1)
      end
    end

    describe '#participant_instances' do
      before { session.add_participant!(character_instance) }

      it 'returns CharacterInstance objects' do
        instances = session.participant_instances
        expect(instances).to include(character_instance)
      end

      it 'returns empty array when no participants' do
        session.update(participant_ids: Sequel.pg_array([], :integer))
        expect(session.participant_instances).to eq([])
      end
    end
  end

  describe 'chaos management' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering', chaos_level: 5) }

    describe '#increase_chaos!' do
      it 'increases chaos level' do
        session.increase_chaos!
        expect(session.chaos_level).to eq(6)
      end

      it 'does not exceed MAX_CHAOS' do
        session.update(chaos_level: 9)
        session.increase_chaos!
        expect(session.chaos_level).to eq(9)
      end
    end

    describe '#decrease_chaos!' do
      it 'decreases chaos level' do
        session.decrease_chaos!
        expect(session.chaos_level).to eq(4)
      end

      it 'does not go below MIN_CHAOS' do
        session.update(chaos_level: 1)
        session.decrease_chaos!
        expect(session.chaos_level).to eq(1)
      end
    end

    describe '#adjust_chaos!' do
      it 'adjusts chaos by positive amount' do
        session.adjust_chaos!(2)
        expect(session.chaos_level).to eq(7)
      end

      it 'adjusts chaos by negative amount' do
        session.adjust_chaos!(-2)
        expect(session.chaos_level).to eq(3)
      end
    end

    describe '#random_event_triggered?' do
      it 'returns true for doubles at or below chaos level' do
        session.update(chaos_level: 5)
        expect(session.random_event_triggered?(55)).to be true
        expect(session.random_event_triggered?(33)).to be true
      end

      it 'returns false for doubles above chaos level' do
        session.update(chaos_level: 5)
        expect(session.random_event_triggered?(66)).to be false
      end

      it 'returns false for non-doubles' do
        expect(session.random_event_triggered?(57)).to be false
      end
    end
  end

  describe 'lifecycle methods' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }

    describe '#start_running!' do
      it 'sets status to running' do
        session.start_running!
        expect(session.running?).to be true
      end

      it 'sets started_at timestamp' do
        session.start_running!
        expect(session.started_at).not_to be_nil
      end
    end

    describe '#start_climax!' do
      it 'sets status to climax' do
        session.start_climax!
        expect(session.climax?).to be true
      end
    end

    describe '#resolve!' do
      it 'sets status to resolved' do
        session.resolve!(:success)
        expect(session.resolved?).to be true
      end

      it 'sets resolution_type' do
        session.resolve!(:success)
        expect(session.resolution_type).to eq('success')
      end

      it 'sets resolved_at timestamp' do
        session.resolve!(:failure)
        expect(session.resolved_at).not_to be_nil
      end
    end

    describe '#abandon!' do
      it 'sets status to abandoned' do
        session.abandon!
        expect(session.abandoned?).to be true
      end

      it 'sets resolution_type to abandoned' do
        session.abandon!
        expect(session.resolution_type).to eq('abandoned')
      end
    end
  end

  describe 'world state tracking' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }

    describe '#track_npc_spawned!' do
      it 'adds NPC to world_state' do
        session.track_npc_spawned!('Guard Captain')
        expect(session.world_state['npcs_spawned']).to include('Guard Captain')
      end
    end

    describe '#track_item_spawned!' do
      it 'adds item to world_state' do
        session.track_item_spawned!('Ancient Sword')
        expect(session.world_state['items_appeared']).to include('Ancient Sword')
      end
    end

    describe '#track_secret_revealed!' do
      it 'adds secret to world_state' do
        session.track_secret_revealed!('The butler did it')
        expect(session.world_state['secrets_revealed']).to include('The butler did it')
      end
    end
  end

  describe 'location management' do
    let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'gathering') }
    let(:other_room) { create(:room, room_type: 'plaza', location: location) }

    describe '#move_to!' do
      it 'updates current_room_id' do
        session.move_to!(other_room)
        expect(session.current_room_id).to eq(other_room.id)
      end

      it 'tracks location used' do
        session.move_to!(other_room)
        expect(session.location_ids_used.to_a).to include(other_room.location_id)
      end
    end
  end

  describe 'constants' do
    it 'defines valid statuses' do
      expect(AutoGmSession::STATUSES).to include('gathering', 'running', 'resolved')
    end

    it 'defines valid resolution types' do
      expect(AutoGmSession::RESOLUTION_TYPES).to include('success', 'failure', 'abandoned')
    end

    it 'defines chaos bounds via GameConfig' do
      expect(GameConfig::AutoGm::CHAOS[:minimum]).to eq(1)
      expect(GameConfig::AutoGm::CHAOS[:maximum]).to eq(9)
      expect(GameConfig::AutoGm::CHAOS[:default]).to eq(5)
    end
  end

  describe 'class methods' do
    describe '.active' do
      let!(:active_session) { AutoGmSession.create(starting_room_id: room.id, status: 'running') }
      let!(:resolved_session) { AutoGmSession.create(starting_room_id: room.id, status: 'resolved') }

      it 'returns only active sessions' do
        expect(AutoGmSession.active.all).to include(active_session)
        expect(AutoGmSession.active.all).not_to include(resolved_session)
      end
    end

    describe '.in_room' do
      let!(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'running') }

      it 'returns sessions in specific room' do
        expect(AutoGmSession.in_room(room).all).to include(session)
      end
    end
  end
end
