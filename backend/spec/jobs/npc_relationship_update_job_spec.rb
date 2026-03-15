# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcRelationshipUpdateJob do
  let(:archetype) { create(:npc_archetype, behavior_pattern: 'neutral') }
  let(:npc_character) { create(:character, :npc, forename: 'Mara', npc_archetype: archetype) }
  let(:pc_character) { create(:character, forename: 'Alex') }
  let(:relationship) { double('NpcRelationship', record_interaction: true) }

  describe '#perform' do
    it 'evaluates and records interaction deltas' do
      allow(NpcRelationship).to receive(:find_or_create_for).and_return(relationship)
      allow(NpcAnimationHandler).to receive(:send)
        .with(:evaluate_interaction_deltas, hash_including(npc_name: 'Mara'))
        .and_return({ sentiment_delta: 0.1, trust_delta: 0.05, notable_event: 'Helpful exchange' })

      described_class.new.perform(npc_character.id, pc_character.id, 'hello there', 'Mara nods.')

      expect(NpcRelationship).to have_received(:find_or_create_for).with(npc: npc_character, pc: pc_character)
      expect(relationship).to have_received(:record_interaction).with(
        sentiment_delta: 0.1,
        trust_delta: 0.05,
        notable_event: 'Helpful exchange'
      )
    end

    it 'skips when either character is missing' do
      expect(NpcRelationship).not_to receive(:find_or_create_for)

      expect {
        described_class.new.perform(npc_character.id, 999_999, 'hello', 'response')
      }.not_to raise_error
    end
  end
end
