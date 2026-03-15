# frozen_string_literal: true

RSpec.describe NarrativeExtractionService do
  describe '.extract_batch' do
    it 'returns result hash with processed count' do
      result = NarrativeExtractionService.extract_batch(limit: 5)
      expect(result).to include(:processed, :entities, :relationships, :errors)
    end

    it 'skips already-extracted memories' do
      memory = create(:world_memory)
      create(:narrative_extraction_log, world_memory: memory, success: true)
      result = NarrativeExtractionService.extract_batch(limit: 5)
      expect(result[:processed]).to eq(0)
    end
  end

  describe '.extract_comprehensive' do
    let(:memory) { create(:world_memory, summary: 'Alice and Bob fought the dragon at Iron Mines') }

    it 'returns a result hash' do
      allow(LLM::Client).to receive(:generate).and_return(
        '{"entities": [{"name": "Alice", "type": "character"}, {"name": "Bob", "type": "character"}], "relationships": []}'
      )
      result = NarrativeExtractionService.extract_comprehensive(memory)
      expect(result).to include(:entities, :relationships)
    end

    it 'creates an extraction log' do
      allow(LLM::Client).to receive(:generate).and_return(
        '{"entities": [], "relationships": []}'
      )
      expect {
        NarrativeExtractionService.extract_comprehensive(memory)
      }.to change { NarrativeExtractionLog.count }.by(1)
    end

    it 'does not re-extract already processed memories' do
      create(:narrative_extraction_log, world_memory: memory, success: true)
      result = NarrativeExtractionService.extract_comprehensive(memory)
      expect(result[:entities]).to eq(0)
    end
  end

  describe 'entity deduplication' do
    it 'finds existing entity by name match' do
      create(:narrative_entity, name: 'Elder Dragon')
      allow(LLM::Client).to receive(:generate).and_return(
        '{"entities": [{"name": "Elder Dragon", "type": "character", "description": "A dragon"}], "relationships": []}'
      )
      memory = create(:world_memory, summary: 'The Elder Dragon attacked')
      NarrativeExtractionService.extract_comprehensive(memory)
      expect(NarrativeEntity.where(name: 'Elder Dragon').count).to eq(1)
    end

    it 'finds existing entity by alias' do
      create(:narrative_entity, name: 'Elder Wyrm Ignathor', aliases: ['Ignathor', 'The Dragon'])
      allow(LLM::Client).to receive(:generate).and_return(
        '{"entities": [{"name": "Ignathor", "type": "character"}], "relationships": []}'
      )
      memory = create(:world_memory, summary: 'Ignathor stirred')
      NarrativeExtractionService.extract_comprehensive(memory)
      expect(NarrativeEntity.where(Sequel.ilike(:name, '%ignathor%')).count).to eq(1)
    end
  end

  describe 'normalize_entity_type' do
    it 'maps person to character' do
      result = NarrativeExtractionService.send(:normalize_entity_type, 'person')
      expect(result).to eq('character')
    end

    it 'maps place to location' do
      result = NarrativeExtractionService.send(:normalize_entity_type, 'place')
      expect(result).to eq('location')
    end

    it 'returns valid types unchanged' do
      NarrativeEntity::ENTITY_TYPES.each do |type|
        result = NarrativeExtractionService.send(:normalize_entity_type, type)
        expect(result).to eq(type)
      end
    end

    it 'defaults unknown types to concept' do
      result = NarrativeExtractionService.send(:normalize_entity_type, 'unknown_thing')
      expect(result).to eq('concept')
    end
  end
end
