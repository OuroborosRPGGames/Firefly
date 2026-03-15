# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmActionExecutor do
  include_context 'auto_gm_setup'

  let(:decision) do
    {
      action_type: 'emit',
      params: { 'emit_text' => 'The shadows gather...' },
      reasoning: 'Test reasoning',
      thinking_tokens: 100
    }
  end

  before do
    allow(action).to receive(:complete!)
    allow(action).to receive(:fail!)
    allow(action).to receive(:failed?).and_return(false)
    allow(action).to receive(:update)
    allow(action).to receive(:action_data).and_return({})
  end

  describe '.execute' do
    context 'with emit action' do
      it 'creates action record' do
        expect(AutoGmAction).to receive(:create_with_next_sequence).with(
          session_id: session.id,
          attributes: hash_including(
            action_type: 'emit',
            status: 'pending'
          )
        ).and_return(action)
        described_class.execute(session, decision)
      end

      it 'broadcasts to room' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end

      it 'marks action complete on success' do
        expect(action).to receive(:complete!)
        described_class.execute(session, decision)
      end

      it 'returns the action' do
        result = described_class.execute(session, decision)
        expect(result).to eq(action)
      end
    end

    context 'with roll_request action' do
      let(:decision) do
        {
          action_type: 'roll_request',
          params: {
            'roll_type' => 'Perception',
            'roll_dc' => 15,
            'roll_stat' => 'awareness'
          },
          reasoning: 'Test'
        }
      end

      it 'broadcasts roll request to participants' do
        expect(BroadcastService).to receive(:to_character).at_least(:once)
        described_class.execute(session, decision)
      end

      it 'stores roll data in action' do
        expect(action).to receive(:update).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with move_characters action' do
      let(:destination) { double('Destination', id: 99, name: 'Dark Cave') }
      let(:decision) do
        {
          action_type: 'move_characters',
          params: { 'destination_room_id' => 99 },
          reasoning: 'Test'
        }
      end

      before do
        allow(Room).to receive(:[]).with(99).and_return(destination)
      end

      it 'updates session current room' do
        expect(session).to receive(:update).with(hash_including(current_room_id: destination.id))
        described_class.execute(session, decision)
      end

      it 'broadcasts movement message' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end

      context 'when MovementService is available' do
        it 'uses MovementService for character movement' do
          expect(MovementService).to receive(:start_movement).at_least(:once)
          described_class.execute(session, decision)
        end
      end
    end

    context 'with spawn_npc action' do
      let(:archetype) { double('NpcArchetype', id: 1, name: 'Guard') }
      let(:spawned_npc) { double('CharacterInstance', id: 50, character_id: 51) }
      let(:decision) do
        {
          action_type: 'spawn_npc',
          params: {
            'npc_archetype_hint' => 'Guard',
            'npc_disposition' => 'hostile'
          },
          reasoning: 'Test'
        }
      end

      before do
        stub_const('NpcArchetype', Class.new)
        allow(NpcArchetype).to receive(:where).and_return(double('Dataset', first: archetype))
        stub_const('NpcSpawnService', Class.new)
        allow(NpcSpawnService).to receive(:spawn_from_template).and_return(spawned_npc)
      end

      it 'finds matching archetype' do
        expect(NpcArchetype).to receive(:where).with(name: 'Guard').and_return(double('Dataset', first: archetype))
        described_class.execute(session, decision)
      end

      it 'spawns NPC using NpcSpawnService' do
        expect(NpcSpawnService).to receive(:spawn_from_template)
        described_class.execute(session, decision)
      end

      it 'broadcasts NPC arrival' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end

      it 'updates world state with spawned NPC' do
        expect(session).to receive(:update).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with spawn_item action' do
      let(:decision) do
        {
          action_type: 'spawn_item',
          params: { 'item_description' => 'A glowing key' },
          reasoning: 'Test'
        }
      end

      it 'broadcasts item discovery' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end

      it 'updates world state with item' do
        expect(session).to receive(:update).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with reveal_secret action' do
      let(:decision) do
        {
          action_type: 'reveal_secret',
          params: { 'secret_index' => 0 },
          reasoning: 'Test'
        }
      end

      it 'broadcasts revelation' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with trigger_twist action' do
      let(:decision) do
        {
          action_type: 'trigger_twist',
          params: {},
          reasoning: 'Test'
        }
      end

      before do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('secrets_twists' => { 'twist_description' => 'The ally betrays you!' })
        )
      end

      it 'broadcasts twist' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end

      it 'adjusts chaos level' do
        expect(session).to receive(:adjust_chaos!).with(1)
        described_class.execute(session, decision)
      end
    end

    context 'with advance_stage action' do
      let(:decision) do
        {
          action_type: 'advance_stage',
          params: {},
          reasoning: 'Test'
        }
      end

      it 'advances the stage' do
        expect(session).to receive(:advance_stage!)
        described_class.execute(session, decision)
      end

      it 'broadcasts stage transition' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with start_climax action' do
      let(:decision) do
        {
          action_type: 'start_climax',
          params: {},
          reasoning: 'Test'
        }
      end

      it 'updates session status to climax' do
        expect(session).to receive(:update).with(hash_including(status: 'climax'))
        described_class.execute(session, decision)
      end

      it 'broadcasts climax start' do
        expect(BroadcastService).to receive(:to_room).at_least(:once)
        described_class.execute(session, decision)
      end
    end

    context 'with resolve_session action' do
      let(:decision) do
        {
          action_type: 'resolve_session',
          params: { 'resolution_type' => 'success' },
          reasoning: 'Test'
        }
      end

      context 'when ResolutionService is available' do
        before do
          stub_const('AutoGm::AutoGmResolutionService', Class.new)
          allow(AutoGm::AutoGmResolutionService).to receive(:resolve)
        end

        it 'delegates to ResolutionService' do
          expect(AutoGm::AutoGmResolutionService).to receive(:resolve).with(
            session,
            resolution_type: :success
          )
          described_class.execute(session, decision)
        end
      end
    end

    context 'with unknown action type' do
      let(:decision) do
        {
          action_type: 'unknown_action',
          params: {},
          reasoning: 'Test'
        }
      end

      it 'marks action as failed' do
        expect(action).to receive(:fail!).with(/Unknown action type/)
        described_class.execute(session, decision)
      end
    end

    context 'when exception occurs' do
      before do
        allow(BroadcastService).to receive(:to_room).and_raise(StandardError.new('Broadcast error'))
      end

      it 'marks action as failed' do
        expect(action).to receive(:fail!).with('Broadcast error')
        described_class.execute(session, decision)
      end

      it 'returns the action' do
        result = described_class.execute(session, decision)
        expect(result).to eq(action)
      end
    end
  end

  describe '.execute_batch' do
    let(:decisions) do
      [
        { action_type: 'emit', params: { 'emit_text' => 'First' }, reasoning: 'Test' },
        { action_type: 'emit', params: { 'emit_text' => 'Second' }, reasoning: 'Test' }
      ]
    end

    it 'executes each decision in sequence' do
      expect(AutoGmAction).to receive(:create_with_next_sequence).twice.and_return(action)
      described_class.execute_batch(session, decisions)
    end

    it 'returns array of actions' do
      result = described_class.execute_batch(session, decisions)
      expect(result.length).to eq(2)
    end
  end

  describe 'private methods' do
    describe '#find_archetype' do
      before do
        stub_const('NpcArchetype', Class.new)
      end

      context 'with exact name match' do
        let(:archetype) { double('Archetype') }

        before do
          allow(NpcArchetype).to receive(:where).with(name: 'Guard').and_return(
            double('Dataset', first: archetype)
          )
        end

        it 'finds archetype by exact name' do
          result = described_class.send(:find_archetype, 'Guard')
          expect(result).to eq(archetype)
        end
      end

      it 'returns nil for nil hint' do
        result = described_class.send(:find_archetype, nil)
        expect(result).to be_nil
      end
    end

    describe '#update_world_state' do
      it 'appends hash values to arrays' do
        allow(session).to receive(:world_state).and_return({})
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['npcs_spawned']).to eq([{ name: 'Test' }])
        end
        described_class.send(:update_world_state, session, 'npcs_spawned', { name: 'Test' })
      end

      it 'appends string values to arrays' do
        allow(session).to receive(:world_state).and_return({})
        expect(session).to receive(:update) do |args|
          expect(args[:world_state]['secrets_revealed']).to eq(['A secret'])
        end
        described_class.send(:update_world_state, session, 'secrets_revealed', 'A secret')
      end
    end

    describe '#next_sequence_number' do
      it 'returns 1 for first action' do
        allow(auto_gm_actions_dataset).to receive(:max).with(:sequence_number).and_return(nil)
        result = described_class.send(:next_sequence_number, session)
        expect(result).to eq(1)
      end

      it 'increments from last sequence number' do
        allow(auto_gm_actions_dataset).to receive(:max).with(:sequence_number).and_return(5)
        result = described_class.send(:next_sequence_number, session)
        expect(result).to eq(6)
      end
    end
  end
end
