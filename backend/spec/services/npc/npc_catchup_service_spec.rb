# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcCatchupService do
  let(:world) { create(:world) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, location: location) }
  let(:archetype) { create(:npc_archetype, behavior_pattern: 'friendly', animation_level: 'medium') }
  let(:npc) { create(:character, :npc, npc_archetype: archetype) }
  let(:npc_instance) { create(:character_instance, character: npc, current_room: room, online: true) }

  before do
    # Stub LLM calls
    allow(LLM::Client).to receive(:generate).and_return(
      { success: true, text: 'Generated catch-up text about the NPC.' }
    )
    # Stub embedding storage
    allow(Embedding).to receive(:store)
  end

  describe '.ensure_caught_up!' do
    context 'when NPC has no interaction memories' do
      it 'returns early without generating anything' do
        expect(LLM::Client).not_to receive(:generate)
        NpcCatchupService.ensure_caught_up!(npc_instance)
      end
    end

    context 'when last interaction was less than 1 day ago' do
      before do
        NpcMemory.create(
          character_id: npc.id,
          content: 'Recent interaction',
          memory_type: 'interaction',
          memory_at: Time.now - 3600 # 1 hour ago
        )
      end

      it 'returns early without generating anything' do
        expect(LLM::Client).not_to receive(:generate)
        NpcCatchupService.ensure_caught_up!(npc_instance)
      end
    end

    context 'when already caught up since last interaction' do
      before do
        NpcMemory.create(
          character_id: npc.id,
          content: 'Old interaction',
          memory_type: 'interaction',
          memory_at: Time.now - 3 * 86_400 # 3 days ago
        )
        npc_instance.update(last_catchup_at: Time.now - 86_400) # caught up 1 day ago
      end

      it 'returns early without generating anything' do
        expect(LLM::Client).not_to receive(:generate)
        NpcCatchupService.ensure_caught_up!(npc_instance)
      end
    end

    context 'when catch-up is needed (gap > 1 day, not already caught up)' do
      before do
        NpcMemory.create(
          character_id: npc.id,
          content: 'Old interaction with player',
          memory_type: 'interaction',
          memory_at: Time.now - 3 * 86_400 # 3 days ago
        )
      end

      it 'generates a location recap WorldMemory' do
        expect {
          NpcCatchupService.ensure_caught_up!(npc_instance)
        }.to change(WorldMemory, :count).by(1)

        recap = WorldMemory.last
        expect(recap.source_type).to eq('location_recap')
        expect(recap.publicity_level).to eq('public')
        expect(recap.importance).to eq(4)
      end

      it 'generates an NPC reflection NpcMemory' do
        # The interaction memory already exists, plus we expect a new reflection
        expect {
          NpcCatchupService.ensure_caught_up!(npc_instance)
        }.to change { NpcMemory.where(character_id: npc.id, memory_type: 'reflection').count }.by(1)

        reflection = NpcMemory.where(character_id: npc.id, memory_type: 'reflection').last
        expect(reflection).not_to be_nil
        expect(reflection.importance).to eq(5)
      end

      it 'sets abstraction_level 1 for gaps under 7 days' do
        NpcCatchupService.ensure_caught_up!(npc_instance)

        reflection = NpcMemory.where(character_id: npc.id, memory_type: 'reflection').last
        expect(reflection.abstraction_level).to eq(1)
      end

      it 'sets abstraction_level 2 for gaps of 7+ days' do
        NpcMemory.where(character_id: npc.id, memory_type: 'interaction').update(
          memory_at: Time.now - 10 * 86_400
        )

        NpcCatchupService.ensure_caught_up!(npc_instance)

        reflection = NpcMemory.where(character_id: npc.id, memory_type: 'reflection').last
        expect(reflection.abstraction_level).to eq(2)
      end

      it 'updates last_catchup_at on the instance' do
        NpcCatchupService.ensure_caught_up!(npc_instance)

        npc_instance.refresh
        expect(npc_instance.last_catchup_at).not_to be_nil
      end

      it 'reuses existing location recap if recent one exists' do
        # Pre-create a location recap linked to the room
        recap = WorldMemory.create(
          summary: 'Existing recap',
          started_at: Time.now - 7 * 86_400,
          ended_at: Time.now,
          memory_at: Time.now - 86_400,
          source_type: 'location_recap',
          publicity_level: 'public',
          importance: 4
        )
        recap.add_location!(room, is_primary: true)

        expect {
          NpcCatchupService.ensure_caught_up!(npc_instance)
        }.to change(WorldMemory, :count).by(0)
          .and change { NpcMemory.where(character_id: npc.id, memory_type: 'reflection').count }.by(1)
      end

      it 'stores embeddings for generated memories' do
        NpcCatchupService.ensure_caught_up!(npc_instance)

        # One for location recap, one for NPC reflection
        expect(Embedding).to have_received(:store).at_least(2).times
      end
    end

    context 'error handling' do
      before do
        NpcMemory.create(
          character_id: npc.id,
          content: 'Old interaction',
          memory_type: 'interaction',
          memory_at: Time.now - 3 * 86_400
        )
      end

      it 'does not raise on LLM failure' do
        allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'API error' })

        expect {
          NpcCatchupService.ensure_caught_up!(npc_instance)
        }.not_to raise_error
      end

      it 'does not raise on unexpected errors' do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError.new('boom'))

        expect {
          NpcCatchupService.ensure_caught_up!(npc_instance)
        }.not_to raise_error
      end
    end
  end

  describe '.gather_npc_goals' do
    it 'uses active status goals without schema errors' do
      NpcGoal.create(
        character_id: npc.id,
        goal_type: 'short_term',
        description: 'Patrol the courtyard',
        status: 'active',
        priority: 2
      )

      NpcGoal.create(
        character_id: npc.id,
        goal_type: 'long_term',
        description: 'This should not show up',
        status: 'completed',
        priority: 1
      )

      allow(described_class).to receive(:warn)

      output = described_class.send(:gather_npc_goals, npc)

      expect(output).to include('[short_term] Patrol the courtyard')
      expect(output).not_to include('This should not show up')
      expect(described_class).not_to have_received(:warn)
    end
  end
end
