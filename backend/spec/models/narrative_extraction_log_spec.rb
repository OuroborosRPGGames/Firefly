# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeExtractionLog, type: :model do
  describe 'validations' do
    let(:log) { create(:narrative_extraction_log) }

    it 'requires world_memory_id' do
      log.world_memory_id = nil
      expect(log.valid?).to be false
    end

    it 'requires extraction_tier' do
      log.extraction_tier = nil
      expect(log.valid?).to be false
    end

    it 'rejects unknown extraction tiers' do
      log.extraction_tier = 'invalid'
      expect(log.valid?).to be false
    end

    it 'accepts all configured tiers' do
      described_class::TIERS.each do |tier|
        log.extraction_tier = tier
        expect(log.valid?).to be true
      end
    end

    it 'enforces one extraction log per world_memory' do
      memory = create(:world_memory)
      create(:narrative_extraction_log, world_memory: memory)
      duplicate = described_class.new(world_memory_id: memory.id, extraction_tier: 'batch')

      expect(duplicate.valid?).to be false
    end
  end

  describe '.extracted?' do
    let(:memory) { create(:world_memory) }

    it 'returns false when no successful extraction exists' do
      create(:narrative_extraction_log, world_memory: memory, success: false)
      expect(described_class.extracted?(memory.id)).to be false
    end

    it 'returns true when a successful extraction exists' do
      create(:narrative_extraction_log, world_memory: memory, success: true)
      expect(described_class.extracted?(memory.id)).to be true
    end
  end
end
