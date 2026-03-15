# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TriggerActivation do
  let(:character) { create(:character) }
  let(:trigger) { create(:trigger, name: 'Test Trigger') }

  describe 'validations' do
    it 'requires trigger_id' do
      activation = described_class.new(source_type: 'character')
      expect(activation.valid?).to be false
    end

    it 'requires source_type' do
      activation = described_class.new(trigger_id: trigger.id)
      expect(activation.valid?).to be false
    end

    it 'validates source_type is in allowed list' do
      activation = described_class.new(trigger_id: trigger.id, source_type: 'invalid')
      expect(activation.valid?).to be false
    end

    it 'is valid with required fields' do
      activation = described_class.new(
        trigger_id: trigger.id,
        source_type: 'character'
      )
      expect(activation.valid?).to be true
    end

    it 'accepts npc as source_type' do
      activation = described_class.new(trigger_id: trigger.id, source_type: 'npc')
      expect(activation.valid?).to be true
    end

    it 'accepts system as source_type' do
      activation = described_class.new(trigger_id: trigger.id, source_type: 'system')
      expect(activation.valid?).to be true
    end
  end

  describe '#summary' do
    it 'returns human-readable summary' do
      activation = described_class.new(
        trigger: trigger,
        source_type: 'character',
        source_character: character,
        activated_at: Time.new(2024, 1, 15, 10, 30, 0)
      )
      summary = activation.summary
      expect(summary).to include('Test Trigger')
      expect(summary).to include('character')
    end
  end

  describe '#context_value' do
    it 'returns value for key' do
      activation = described_class.new(context_data: { 'key1' => 'value1' })
      expect(activation.context_value('key1')).to eq('value1')
    end

    it 'returns nil for missing key' do
      activation = described_class.new(context_data: {})
      expect(activation.context_value('missing')).to be_nil
    end

    it 'handles nil context_data' do
      activation = described_class.new(context_data: nil)
      expect(activation.context_value('key')).to be_nil
    end
  end

  describe '#successful?' do
    it 'returns true when action executed and succeeded' do
      activation = described_class.new(action_executed: true, action_success: true)
      expect(activation.successful?).to be true
    end

    it 'returns false when action not executed' do
      activation = described_class.new(action_executed: false, action_success: true)
      expect(activation.successful?).to be false
    end

    it 'returns false when action failed' do
      activation = described_class.new(action_executed: true, action_success: false)
      expect(activation.successful?).to be false
    end
  end

  describe '#llm_matched?' do
    it 'returns true when llm_confidence is set' do
      activation = described_class.new(llm_confidence: 0.85)
      expect(activation.llm_matched?).to be true
    end

    it 'returns false when llm_confidence is nil' do
      activation = described_class.new(llm_confidence: nil)
      expect(activation.llm_matched?).to be false
    end
  end

  describe '#confidence_percentage' do
    it 'returns formatted percentage' do
      activation = described_class.new(llm_confidence: 0.856)
      expect(activation.confidence_percentage).to eq('85.6%')
    end

    it 'returns nil when llm_confidence is nil' do
      activation = described_class.new(llm_confidence: nil)
      expect(activation.confidence_percentage).to be_nil
    end
  end
end
