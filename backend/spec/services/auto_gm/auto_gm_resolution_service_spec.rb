# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmResolutionService do
  include_context 'auto_gm_setup'

  let(:world_memory) { double('WorldMemory', id: 1, add_character!: true, add_location!: true) }
  let(:wallet) { double('Wallet', add: true) }
  let(:currency) { double('Currency', id: 1) }
  let(:universe) { double('Universe', id: 1) }

  before do
    allow(session).to receive(:resolved?).and_return(false)
    allow(session).to receive(:resolve!)
    allow(session).to receive(:participant_instances).and_return([char_instance])
    allow(session).to receive(:location_ids_used).and_return([1, 2])
    allow(session).to receive(:starting_room).and_return(room)
    allow(session).to receive(:started_at).and_return(Time.now - 3600)
    allow(session).to receive(:resolved_at).and_return(Time.now)
    allow(session).to receive(:resolution_type).and_return('success')
    allow(char_instance).to receive(:character).and_return(character)
    allow(char_instance).to receive(:current_room_id).and_return(room.id)
    allow(DisplayHelper).to receive(:character_display_name).and_return('Test Hero')
  end

  describe '.resolve' do
    context 'when session is already resolved' do
      before do
        allow(session).to receive(:resolved?).and_return(true)
      end

      it 'returns error' do
        result = described_class.resolve(session, resolution_type: :success)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Session already resolved')
      end
    end

    context 'with success resolution' do
      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        allow(session).to receive(:sketch).and_return(sketch)
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
      end

      it 'resolves the session' do
        expect(session).to receive(:resolve!).with(:success)
        described_class.resolve(session, resolution_type: :success)
      end

      it 'creates world memory' do
        expect(WorldMemory).to receive(:create).with(hash_including(
          importance: 7,
          source_type: 'activity'
        ))
        described_class.resolve(session, resolution_type: :success)
      end

      it 'applies rewards' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'rewards' => ['100 gold'] })
        )
        allow(AutoGm::LootTracker).to receive(:remaining_allowance).and_return(1000)
        allow(AutoGm::LootTracker).to receive(:record_loot)
        allow(char_instance).to receive(:current_room).and_return(room)
        allow(room).to receive(:location).and_return(double('Location', zone: double('Zone', world: double('World', universe: universe))))
        allow(Currency).to receive(:where).and_return(double('Dataset', first: currency))
        allow(char_instance).to receive(:wallets_dataset).and_return(double('Dataset', first: wallet))

        expect(wallet).to receive(:add).with(100)
        described_class.resolve(session, resolution_type: :success)
      end

      it 'broadcasts resolution' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(:content),
          hash_including(type: :auto_gm_resolution)
        )
        described_class.resolve(session, resolution_type: :success)
      end

      it 'returns success' do
        result = described_class.resolve(session, resolution_type: :success)
        expect(result[:success]).to be true
      end

      it 'extracts narrative from reloaded memory record' do
        reloaded_memory = double('WorldMemoryRecord')
        allow(WorldMemory).to receive(:[]).with(world_memory.id).and_return(reloaded_memory)

        allow(NarrativeExtractionService).to receive(:extract_comprehensive)
        thread_double = double('Thread')
        allow(thread_double).to receive(:respond_to?).with(:report_on_exception=).and_return(false)
        allow(Thread).to receive(:new) do |memory_id, &block|
          block.call(memory_id)
          thread_double
        end

        described_class.resolve(session, resolution_type: :success)

        expect(NarrativeExtractionService).to have_received(:extract_comprehensive).with(reloaded_memory)
      end
    end

    context 'with failure resolution' do
      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
      end

      it 'creates memory with lower importance' do
        expect(WorldMemory).to receive(:create).with(hash_including(importance: 5))
        described_class.resolve(session, resolution_type: :failure)
      end

      it 'logs consequences to world_state' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['money_loss:50'] })
        )
        expect(session).to receive(:update).with(hash_including(:world_state))
        described_class.resolve(session, resolution_type: :failure)
      end
    end

    context 'with money_loss peril' do
      let(:wallet) { double('Wallet', balance: 200, remove: true) }
      let(:wallets_dataset) { double('Dataset', first: wallet) }
      let(:location) { double('Location', zone: double('Zone', world: double('World', universe: universe))) }

      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
        allow(Currency).to receive(:where).and_return(double('Dataset', first: currency))
        allow(char_instance).to receive(:wallets_dataset).and_return(wallets_dataset)
        allow(char_instance).to receive(:current_room).and_return(room)
        allow(room).to receive(:location).and_return(location)
      end

      it 'actually deducts money from wallet' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['money_loss:50'] })
        )

        expect(wallet).to receive(:remove).with(50)
        described_class.resolve(session, resolution_type: :failure)
      end

      it 'caps loss at wallet balance' do
        allow(wallet).to receive(:balance).and_return(30)
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['money_loss:100'] })
        )

        expect(wallet).to receive(:remove).with(30)
        described_class.resolve(session, resolution_type: :failure)
      end
    end

    context 'with injury peril' do
      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
        allow(char_instance).to receive(:health).and_return(6)
        allow(char_instance).to receive(:respond_to?).with(:health).and_return(true)
      end

      it 'actually reduces character health' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['injury:2'] })
        )

        expect(char_instance).to receive(:update).with(health: 4)
        described_class.resolve(session, resolution_type: :failure)
      end

      it 'caps injury at 3 HP' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['injury:10'] })
        )

        # Should cap at 3 HP even if larger value specified
        expect(char_instance).to receive(:update).with(health: 3)
        described_class.resolve(session, resolution_type: :failure)
      end

      it 'does not reduce health below 1' do
        allow(char_instance).to receive(:health).and_return(2)
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['injury:3'] })
        )

        expect(char_instance).to receive(:update).with(health: 1)
        described_class.resolve(session, resolution_type: :failure)
      end
    end

    context 'with item_lost peril' do
      let(:test_item) { double('Item', name: 'Old Sword', move_to_room: true) }
      let(:items_dataset) do
        double('Dataset').tap do |d|
          allow(d).to receive(:exclude).and_return(d)
          allow(d).to receive(:all).and_return([test_item])
        end
      end

      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
        allow(char_instance).to receive(:objects_dataset).and_return(items_dataset)
      end

      it 'actually drops item to room' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['item_lost'] })
        )

        expect(test_item).to receive(:move_to_room).with(room)
        described_class.resolve(session, resolution_type: :failure)
      end
    end

    context 'with item_damage peril' do
      let(:test_item) { double('Item', name: 'Steel Armor', condition: 'good', respond_to?: true, update: true) }
      let(:items_dataset) do
        double('Dataset').tap do |d|
          allow(d).to receive(:exclude).and_return(d)
          allow(d).to receive(:all).and_return([test_item])
        end
      end

      before do
        stub_const('WorldMemory', Class.new)
        allow(WorldMemory).to receive(:create).and_return(world_memory)
        allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
        stub_const('Location', Class.new)
        allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
        allow(char_instance).to receive(:objects_dataset).and_return(items_dataset)
        allow(test_item).to receive(:respond_to?).with(:condition=).and_return(true)
      end

      it 'actually damages item condition' do
        allow(session).to receive(:sketch).and_return(
          sketch.merge('rewards_perils' => { 'perils' => ['item_damage'] })
        )

        expect(test_item).to receive(:update).with(condition: 'worn')
        described_class.resolve(session, resolution_type: :failure)
      end
    end

    context 'when exception occurs' do
      before do
        allow(session).to receive(:resolve!).and_raise(StandardError.new('DB error'))
      end

      it 'returns error' do
        result = described_class.resolve(session, resolution_type: :success)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Resolution error')
      end
    end
  end

  describe '.abandon' do
    before do
      stub_const('WorldMemory', Class.new)
      allow(WorldMemory).to receive(:create).and_return(world_memory)
      allow(AutoGm::AutoGmResolutionService).to receive(:generate_session_summary).and_return('Summary')
      stub_const('Location', Class.new)
      allow(Location).to receive(:[]).and_return(double('Location', rooms: [room]))
    end

    it 'updates session status' do
      expect(session).to receive(:update).with(hash_including(
        status: 'abandoned',
        resolution_type: 'abandoned'
      ))
      described_class.abandon(session, reason: 'Test reason')
    end

    it 'creates minimal world memory' do
      expect(WorldMemory).to receive(:create).with(hash_including(importance: 3))
      described_class.abandon(session, reason: 'Test')
    end

    it 'broadcasts abandonment' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id,
        hash_including(:content),
        hash_including(type: :auto_gm_abandoned)
      )
      described_class.abandon(session, reason: 'Timed out')
    end

    it 'returns success' do
      result = described_class.abandon(session, reason: 'Test')
      expect(result[:success]).to be true
    end
  end

  describe '.generate_session_summary' do
    context 'when best summary exists' do
      let(:summary) { double('AutoGmSummary', content: 'Pre-existing summary') }

      before do
        allow(AutoGmSummary).to receive(:best_for_context).and_return(summary)
      end

      it 'returns existing summary content' do
        result = described_class.generate_session_summary(session)
        expect(result).to eq('Pre-existing summary')
      end
    end

    context 'when no summary exists' do
      before do
        allow(AutoGmSummary).to receive(:best_for_context).and_return(nil)
        allow(auto_gm_actions_dataset).to receive(:where).and_return(
          double('Dataset',
            exclude: double('Dataset',
              order: double('Dataset',
                limit: double('Dataset',
                  all: [double('Action', emit_text: 'Event happened')]))))
        )
      end

      context 'when LLM succeeds' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({
            success: true,
            text: 'Generated summary of the adventure...'
          })
        end

        it 'generates summary via LLM' do
          result = described_class.generate_session_summary(session)
          expect(result).to eq('Generated summary of the adventure...')
        end
      end

      context 'when LLM fails' do
        before do
          allow(LLM::Client).to receive(:generate).and_return({ success: false })
        end

        it 'returns default message' do
          result = described_class.generate_session_summary(session)
          expect(result).to eq("Adventure 'The Lost Temple' concluded.")
        end
      end
    end
  end

  describe 'private methods' do
    describe '#compile_session_log' do
      let(:actions) do
        [
          double('Action', action_type: 'emit', emit_text: 'First event'),
          double('Action', action_type: 'emit', emit_text: 'Second event')
        ]
      end

      before do
        allow(auto_gm_actions_dataset).to receive(:order).and_return(
          double('Dataset', all: actions)
        )
      end

      it 'includes session title' do
        result = described_class.send(:compile_session_log, session)
        expect(result).to include('The Lost Temple')
      end

      it 'includes action emit texts' do
        result = described_class.send(:compile_session_log, session)
        expect(result).to include('First event')
        expect(result).to include('Second event')
      end
    end

    describe '#parse_currency_from_rewards' do
      # Uses actual GameConfig::AutoGm::LOOT[:currency_patterns] which includes:
      # - /(\d+)\s*(?:gold|gp)/i
      # - /\$(\d+)/

      it 'parses gold amounts' do
        rewards = ['100 gold coins', 'A magical sword']
        result = described_class.send(:parse_currency_from_rewards, rewards)
        expect(result).to eq(100)
      end

      it 'parses dollar amounts' do
        rewards = ['$500 in treasure']
        result = described_class.send(:parse_currency_from_rewards, rewards)
        expect(result).to eq(500)
      end

      it 'returns 0 for non-currency rewards' do
        rewards = ['A magic ring', 'Experience']
        result = described_class.send(:parse_currency_from_rewards, rewards)
        expect(result).to eq(0)
      end
    end

    describe '#update_dispositions' do
      let(:pc_character) { double('Character', id: 100) }
      let(:npc_character) { double('Character', id: 200, forename: 'Bandit') }
      let(:npc_instance) { double('CharacterInstance', character: npc_character) }
      let(:relationship) { double('NpcRelationship', sentiment: 0.0, trust: 0.5, record_interaction: true) }

      before do
        allow(session).to receive(:participant_characters).and_return([pc_character])
        allow(session).to receive(:world_state).and_return({
          'npcs_spawned' => [
            { 'id' => 50, 'name' => 'Bandit Captain', 'disposition' => 'hostile' }
          ],
          'disposition_changes' => [
            { 'npc' => 'Bandit Captain', 'change' => 'hostile->friendly' }
          ]
        })
        allow(CharacterInstance).to receive(:[]).with(50).and_return(npc_instance)
        allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)
      end

      it 'updates tracked world_state disposition' do
        expect(session).to receive(:update).with(hash_including(:world_state)) do |attrs|
          world_state = attrs[:world_state]
          expect(world_state['npcs_spawned'][0]['disposition']).to eq('friendly')
        end

        described_class.send(:update_dispositions, session)
      end

      it 'applies relationship updates for participant characters' do
        expect(NpcRelationship).to receive(:find_or_create_for).with(
          npc: npc_character,
          pc: pc_character
        ).and_return(relationship)
        expect(relationship).to receive(:record_interaction).with(hash_including(
          notable_event: include('hostile->friendly')
        ))

        described_class.send(:update_dispositions, session)
      end

      it 'does nothing when no changes are present' do
        allow(session).to receive(:world_state).and_return({
          'npcs_spawned' => [{ 'id' => 50, 'name' => 'Bandit Captain', 'disposition' => 'hostile' }],
          'disposition_changes' => []
        })

        expect(session).not_to receive(:update)
        described_class.send(:update_dispositions, session)
      end
    end

    describe '#cleanup_session_npcs' do
      let(:npc_instance) { double('CharacterInstance', id: 50, update: true) }

      before do
        allow(session).to receive(:world_state).and_return({
          'npcs_spawned' => [{ 'id' => 50, 'role' => 'minion' }]
        })
        allow(CharacterInstance).to receive(:[]).with(50).and_return(npc_instance)
      end

      context 'when NpcSpawnService is available' do
        let(:spawn_inst) { double('NpcSpawnInstance', id: 10) }

        before do
          stub_const('NpcSpawnInstance', Class.new)
          stub_const('NpcSpawnService', Class.new)
          allow(NpcSpawnInstance).to receive(:first)
            .with(character_instance_id: 50, active: true)
            .and_return(spawn_inst)
          allow(NpcSpawnService).to receive(:despawn_npc)
        end

        it 'despawns temporary NPCs' do
          expect(NpcSpawnService).to receive(:despawn_npc).with(spawn_inst)
          described_class.send(:cleanup_session_npcs, session)
        end
      end

      context 'when NpcSpawnService is not available' do
        it 'sets NPC offline' do
          expect(npc_instance).to receive(:update).with(online: false)
          described_class.send(:cleanup_session_npcs, session)
        end
      end

      context 'with ally role' do
        before do
          allow(session).to receive(:world_state).and_return({
            'npcs_spawned' => [{ 'id' => 50, 'role' => 'ally' }]
          })
        end

        it 'does not despawn allies' do
          expect(npc_instance).not_to receive(:update)
          described_class.send(:cleanup_session_npcs, session)
        end
      end
    end

    describe '#broadcast_resolution' do
      it 'broadcasts success message' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: /Victory/),
          hash_including(type: :auto_gm_resolution)
        )
        described_class.send(:broadcast_resolution, session, :success)
      end

      it 'broadcasts failure message' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: /Failed/),
          hash_including(type: :auto_gm_resolution)
        )
        described_class.send(:broadcast_resolution, session, :failure)
      end

      it 'broadcasts abandoned message' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: /Abandoned/),
          hash_including(type: :auto_gm_resolution)
        )
        described_class.send(:broadcast_resolution, session, :abandoned)
      end

      it 'notifies participants in other rooms' do
        other_participant = double('CharacterInstance', current_room_id: 999)
        allow(session).to receive(:participant_instances).and_return([other_participant])
        allow(IcActivityService).to receive(:record)
        allow(IcActivityService).to receive(:record_for)

        expect(BroadcastService).to receive(:to_room)
        expect(BroadcastService).to receive(:to_character).with(
          other_participant,
          hash_including(:content),
          hash_including(type: :auto_gm_resolution)
        )
        described_class.send(:broadcast_resolution, session, :success)
      end
    end
  end
end
