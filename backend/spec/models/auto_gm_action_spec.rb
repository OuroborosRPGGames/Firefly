# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGmAction do
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:session) { AutoGmSession.create(starting_room_id: room.id, status: 'running') }

  describe 'validations' do
    it 'requires session_id' do
      action = AutoGmAction.new(action_type: 'emit', sequence_number: 1)
      expect(action.valid?).to be false
      expect(action.errors[:session_id]).not_to be_empty
    end

    it 'requires action_type' do
      action = AutoGmAction.new(session_id: session.id, sequence_number: 1)
      expect(action.valid?).to be false
      expect(action.errors[:action_type]).not_to be_empty
    end

    it 'requires sequence_number' do
      action = AutoGmAction.new(session_id: session.id, action_type: 'emit')
      expect(action.valid?).to be false
      expect(action.errors[:sequence_number]).not_to be_empty
    end

    it 'validates action_type is in allowed list' do
      action = AutoGmAction.new(session_id: session.id, action_type: 'invalid', sequence_number: 1)
      expect(action.valid?).to be false
    end

    it 'validates status when present' do
      action = AutoGmAction.new(session_id: session.id, action_type: 'emit', sequence_number: 1, status: 'invalid')
      expect(action.valid?).to be false
    end
  end

  describe 'defaults' do
    let(:action) do
      AutoGmAction.create(session_id: session.id, action_type: 'emit', sequence_number: 1)
    end

    it 'sets default status to pending' do
      expect(action.status).to eq('pending')
    end

    it 'initializes action_data as empty hash' do
      expect(action.action_data).to eq({})
    end
  end

  describe 'status methods' do
    let(:action) do
      AutoGmAction.create(session_id: session.id, action_type: 'emit', sequence_number: 1)
    end

    describe '#pending?' do
      it 'returns true when status is pending' do
        expect(action.pending?).to be true
      end
    end

    describe '#completed?' do
      it 'returns true when status is completed' do
        action.update(status: 'completed')
        expect(action.completed?).to be true
      end
    end

    describe '#failed?' do
      it 'returns true when status is failed' do
        action.update(status: 'failed')
        expect(action.failed?).to be true
      end
    end
  end

  describe 'action type checks' do
    let(:action) do
      AutoGmAction.create(session_id: session.id, action_type: 'emit', sequence_number: 1)
    end

    it '#emit? returns true for emit actions' do
      expect(action.emit?).to be true
    end

    it '#roll_request? returns true for roll_request actions' do
      action.update(action_type: 'roll_request')
      expect(action.roll_request?).to be true
    end

    it '#move_characters? returns true for move_characters actions' do
      action.update(action_type: 'move_characters')
      expect(action.move_characters?).to be true
    end

    it '#spawn_npc? returns true for spawn_npc actions' do
      action.update(action_type: 'spawn_npc')
      expect(action.spawn_npc?).to be true
    end

    it '#reveal_secret? returns true for reveal_secret actions' do
      action.update(action_type: 'reveal_secret')
      expect(action.reveal_secret?).to be true
    end

    it '#resolve_session? returns true for resolve_session actions' do
      action.update(action_type: 'resolve_session')
      expect(action.resolve_session?).to be true
    end

    it '#spawn_item? returns true for spawn_item actions' do
      action.update(action_type: 'spawn_item')
      expect(action.spawn_item?).to be true
    end

    it '#trigger_twist? returns true for trigger_twist actions' do
      action.update(action_type: 'trigger_twist')
      expect(action.trigger_twist?).to be true
    end

    it '#advance_stage? returns true for advance_stage actions' do
      action.update(action_type: 'advance_stage')
      expect(action.advance_stage?).to be true
    end

    it '#start_climax? returns true for start_climax actions' do
      action.update(action_type: 'start_climax')
      expect(action.start_climax?).to be true
    end
  end

  describe 'lifecycle methods' do
    let(:action) do
      AutoGmAction.create(session_id: session.id, action_type: 'emit', sequence_number: 1)
    end

    describe '#complete!' do
      it 'sets status to completed' do
        action.complete!
        expect(action.completed?).to be true
      end
    end

    describe '#fail!' do
      it 'sets status to failed' do
        action.fail!
        expect(action.failed?).to be true
      end

      it 'stores error message in action_data' do
        action.fail!('Something went wrong')
        expect(action.action_data['error']).to eq('Something went wrong')
      end
    end
  end

  describe 'action data accessors' do
    describe 'roll_request accessors' do
      let(:action) do
        AutoGmAction.create(
          session_id: session.id,
          action_type: 'roll_request',
          sequence_number: 1,
          action_data: { 'character_id' => 123, 'roll_type' => 'skill', 'dc' => 15, 'stat' => 'STR' }
        )
      end

      it '#roll_character_id returns character_id' do
        expect(action.roll_character_id).to eq(123)
      end

      it '#roll_type returns roll_type' do
        expect(action.roll_type).to eq('skill')
      end

      it '#roll_dc returns dc' do
        expect(action.roll_dc).to eq(15)
      end

      it '#roll_stat returns stat' do
        expect(action.roll_stat).to eq('STR')
      end
    end

    describe 'move_characters accessors' do
      let(:action) do
        AutoGmAction.create(
          session_id: session.id,
          action_type: 'move_characters',
          sequence_number: 1,
          action_data: { 'character_ids' => [1, 2, 3], 'destination_room_id' => 456, 'adverb' => 'run' }
        )
      end

      it '#move_character_ids returns character_ids' do
        expect(action.move_character_ids).to eq([1, 2, 3])
      end

      it '#destination_room_id returns destination' do
        expect(action.destination_room_id).to eq(456)
      end

      it '#movement_adverb returns adverb' do
        expect(action.movement_adverb).to eq('run')
      end

      it '#movement_adverb defaults to walk' do
        action.update(action_data: { 'character_ids' => [1] })
        expect(action.movement_adverb).to eq('walk')
      end
    end

    describe 'spawn_npc accessors' do
      let(:action) do
        AutoGmAction.create(
          session_id: session.id,
          action_type: 'spawn_npc',
          sequence_number: 1,
          action_data: {
            'archetype_id' => 99,
            'npc_archetype_hint' => 'mysterious stranger',
            'disposition' => 'hostile',
            'name_hint' => 'Zara'
          }
        )
      end

      it '#npc_archetype_id returns archetype_id' do
        expect(action.npc_archetype_id).to eq(99)
      end

      it '#npc_archetype_hint returns hint' do
        expect(action.npc_archetype_hint).to eq('mysterious stranger')
      end

      it '#npc_disposition returns disposition' do
        expect(action.npc_disposition).to eq('hostile')
      end

      it '#npc_name_hint returns name_hint' do
        expect(action.npc_name_hint).to eq('Zara')
      end

      it '#spawn_room_id returns room_id' do
        action.update(action_data: { 'room_id' => 42 })
        expect(action.spawn_room_id).to eq(42)
      end
    end

    describe 'spawn_item accessors' do
      let(:action) do
        AutoGmAction.create(
          session_id: session.id,
          action_type: 'spawn_item',
          sequence_number: 1,
          action_data: {
            'pattern_id' => 123,
            'description' => 'a mysterious key'
          }
        )
      end

      it '#item_pattern_id returns pattern_id' do
        expect(action.item_pattern_id).to eq(123)
      end

      it '#item_description returns description' do
        expect(action.item_description).to eq('a mysterious key')
      end
    end

    describe 'advance_stage accessors' do
      let(:action) do
        AutoGmAction.create(
          session_id: session.id,
          action_type: 'advance_stage',
          sequence_number: 1,
          action_data: { 'target_stage' => 3 }
        )
      end

      it '#target_stage returns target_stage' do
        expect(action.target_stage).to eq(3)
      end
    end
  end

  describe '#summary' do
    it 'returns truncated emit text' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'emit',
        sequence_number: 1,
        emit_text: 'a' * 150
      )
      expect(action.summary.length).to be <= 103
      expect(action.summary).to end_with('...')
    end

    it 'returns roll request summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'roll_request',
        sequence_number: 1,
        action_data: { 'roll_type' => 'skill', 'dc' => 15 }
      )
      expect(action.summary).to include('skill')
      expect(action.summary).to include('15')
    end

    it 'returns spawn NPC summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'spawn_npc',
        sequence_number: 1,
        action_data: { 'npc_archetype_hint' => 'guard' }
      )
      expect(action.summary).to include('Spawn NPC')
      expect(action.summary).to include('guard')
    end

    it 'returns resolve summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'resolve_session',
        sequence_number: 1,
        action_data: { 'resolution_type' => 'success' }
      )
      expect(action.summary).to include('success')
    end

    it 'returns spawn item summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'spawn_item',
        sequence_number: 1,
        action_data: { 'description' => 'golden key' }
      )
      expect(action.summary).to include('Spawn item')
      expect(action.summary).to include('golden key')
    end

    it 'returns spawn item unknown when no description' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'spawn_item',
        sequence_number: 1
      )
      expect(action.summary).to include('Spawn item')
      expect(action.summary).to include('unknown')
    end

    it 'returns trigger twist summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'trigger_twist',
        sequence_number: 1
      )
      expect(action.summary).to eq('Trigger the twist')
    end

    it 'returns advance stage summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'advance_stage',
        sequence_number: 1,
        action_data: { 'target_stage' => 2 }
      )
      expect(action.summary).to include('Advance to stage')
      expect(action.summary).to include('2')
    end

    it 'returns start climax summary' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'start_climax',
        sequence_number: 1
      )
      expect(action.summary).to eq('Begin climax')
    end

    it 'returns move_characters summary with unknown room when room not found' do
      action = AutoGmAction.create(
        session_id: session.id,
        action_type: 'move_characters',
        sequence_number: 1,
        action_data: { 'destination_room_id' => 999999 }
      )
      expect(action.summary).to include('Move characters')
      expect(action.summary).to include('unknown')
    end
  end

  describe 'class creation methods' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user, forename: 'TestChar') }

    describe '.create_emit' do
      it 'creates an emit action' do
        action = AutoGmAction.create_emit(session, 'The door creaks open.')
        expect(action.action_type).to eq('emit')
        expect(action.emit_text).to eq('The door creaks open.')
      end

      it 'assigns correct sequence number' do
        action = AutoGmAction.create_emit(session, 'First')
        expect(action.sequence_number).to eq(1)
      end

      it 'stores reasoning if provided' do
        action = AutoGmAction.create_emit(session, 'Text', reasoning: 'Build tension')
        expect(action.ai_reasoning).to eq('Build tension')
      end
    end

    describe '.create_roll_request' do
      it 'creates a roll request action' do
        action = AutoGmAction.create_roll_request(
          session,
          character_id: character.id,
          roll_type: 'skill',
          dc: 15,
          stat: 'DEX'
        )
        expect(action.action_type).to eq('roll_request')
        expect(action.roll_dc).to eq(15)
      end
    end

    describe '.create_move' do
      it 'creates a move action' do
        action = AutoGmAction.create_move(
          session,
          character_ids: [1, 2],
          destination_room_id: room.id,
          adverb: 'rush'
        )
        expect(action.action_type).to eq('move_characters')
        expect(action.move_character_ids).to eq([1, 2])
      end
    end

    describe '.create_spawn_npc' do
      it 'creates a spawn NPC action' do
        action = AutoGmAction.create_spawn_npc(
          session,
          archetype_hint: 'mysterious stranger',
          disposition: 'neutral'
        )
        expect(action.action_type).to eq('spawn_npc')
        expect(action.npc_archetype_hint).to eq('mysterious stranger')
      end
    end

    describe '.create_reveal_secret' do
      it 'creates a reveal secret action' do
        action = AutoGmAction.create_reveal_secret(session, secret_index: 2)
        expect(action.action_type).to eq('reveal_secret')
        expect(action.secret_index).to eq(2)
      end
    end

    describe '.create_resolve' do
      it 'creates a resolve action' do
        action = AutoGmAction.create_resolve(session, resolution_type: 'success')
        expect(action.action_type).to eq('resolve_session')
        expect(action.resolution_type).to eq('success')
      end
    end

    describe '.create_trigger_twist' do
      it 'creates a trigger twist action' do
        action = AutoGmAction.create_trigger_twist(session, reasoning: 'Time to reveal the twist')
        expect(action.action_type).to eq('trigger_twist')
        expect(action.ai_reasoning).to eq('Time to reveal the twist')
      end
    end

    describe '.create_advance_stage' do
      it 'creates an advance stage action' do
        action = AutoGmAction.create_advance_stage(session, target_stage: 3)
        expect(action.action_type).to eq('advance_stage')
        expect(action.target_stage).to eq(3)
      end

      it 'defaults to current_stage + 1 when target_stage not provided' do
        allow(session).to receive(:current_stage).and_return(2)
        action = AutoGmAction.create_advance_stage(session)
        expect(action.target_stage).to eq(3)
      end
    end

    describe '.create_start_climax' do
      it 'creates a start climax action' do
        action = AutoGmAction.create_start_climax(session, reasoning: 'Building to climax')
        expect(action.action_type).to eq('start_climax')
        expect(action.ai_reasoning).to eq('Building to climax')
      end
    end
  end

  describe 'constants' do
    it 'defines valid action types' do
      expect(AutoGmAction::ACTION_TYPES).to include(
        'emit', 'roll_request', 'move_characters', 'spawn_npc',
        'reveal_secret', 'resolve_session'
      )
    end

    it 'defines valid statuses' do
      expect(AutoGmAction::STATUSES).to include('pending', 'completed', 'failed')
    end
  end
end
