# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeEntityMemory, type: :model do
  describe 'validations' do
    let(:entity_memory) { create(:narrative_entity_memory) }

    it 'requires a narrative_entity_id' do
      entity_memory.narrative_entity_id = nil
      expect(entity_memory.valid?).to be false
    end

    it 'requires a world_memory_id' do
      entity_memory.world_memory_id = nil
      expect(entity_memory.valid?).to be false
    end

    it 'validates role is in allowed list when provided' do
      entity_memory.role = 'invalid_role'
      expect(entity_memory.valid?).to be false
    end

    it 'allows all supported role values' do
      NarrativeEntityMemory::ROLES.each do |role|
        entity_memory.role = role
        expect(entity_memory.valid?).to be true
      end
    end

    it 'allows a nil role' do
      entity_memory.role = nil
      expect(entity_memory.valid?).to be true
    end
  end

  describe 'dataset scopes' do
    describe '.reputation_relevant' do
      it 'returns only entries marked reputation_relevant' do
        relevant = create(:narrative_entity_memory, reputation_relevant: true)
        not_relevant = create(:narrative_entity_memory, reputation_relevant: false)

        results = described_class.reputation_relevant.all
        expect(results).to include(relevant)
        expect(results).not_to include(not_relevant)
      end
    end
  end
end
