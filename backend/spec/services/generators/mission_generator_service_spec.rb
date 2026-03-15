# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MissionGeneratorService do
  let(:description) { 'A heist to steal the Duke\'s secret ledger from his manor' }
  let(:setting) { :fantasy }
  let(:difficulty) { :normal }
  let(:location_mode) { :mission_specific }

  let(:brainstorm_result) do
    {
      success: true,
      outputs: { creative_a: 'Ideas from model A...', creative_b: 'Ideas from model B...' },
      seed_terms: %w[mysterious intrigue]
    }
  end

  let(:valid_plan) do
    {
      'title' => 'The Duke\'s Ledger',
      'summary' => 'Steal evidence of corruption.',
      'atype' => 'mission',
      'rounds' => [
        { 'round_number' => 1, 'branch' => 0, 'rtype' => 'standard', 'emit' => 'You arrive...' }
      ],
      'locations' => [],
      'adversaries' => []
    }
  end

  let(:synthesis_result) do
    { success: true, plan: valid_plan }
  end

  let(:mock_activity) do
    activity = double('Activity')
    allow(activity).to receive(:id).and_return(1)
    allow(activity).to receive(:aname).and_return('Test Mission')
    activity
  end

  let(:build_result) do
    {
      success: true,
      activity: mock_activity,
      rooms: {},
      archetypes: {},
      rounds_created: 1,
      errors: []
    }
  end

  before do
    allow(Generators::MissionBrainstormService).to receive(:brainstorm).and_return(brainstorm_result)
    allow(Generators::MissionSynthesisService).to receive(:synthesize).and_return(synthesis_result)
    allow(Generators::MissionBuilderService).to receive(:build).and_return(build_result)
    allow(SeedTermService).to receive(:for_generation).and_return(%w[mysterious intrigue])
  end

  describe '.send(:validate_inputs, ...)' do
    it 'validates required description' do
      result = described_class.send(:validate_inputs, '', location_mode, setting, difficulty)

      expect(result[:valid]).to be false
      expect(result[:errors]).to include('Description is required')
    end

    it 'validates description length' do
      result = described_class.send(:validate_inputs, 'short', location_mode, setting, difficulty)

      expect(result[:valid]).to be false
      expect(result[:errors]).to include('Description must be at least 10 characters')
    end

    it 'validates location_mode' do
      result = described_class.send(:validate_inputs, description, :invalid_mode, setting, difficulty)

      expect(result[:valid]).to be false
      expect(result[:errors].first).to include('Invalid location_mode')
    end

    it 'validates setting' do
      result = described_class.send(:validate_inputs, description, location_mode, :invalid_setting, difficulty)

      expect(result[:valid]).to be false
      expect(result[:errors].first).to include('Invalid setting')
    end

    it 'accepts valid inputs' do
      result = described_class.send(:validate_inputs, description, location_mode, setting, difficulty)

      expect(result[:valid]).to be true
      expect(result[:errors]).to be_empty
    end
  end

  describe '.cancel' do
    it 'cancels running job' do
      job = double('GenerationJob')
      allow(job).to receive(:running?).and_return(true)
      allow(job).to receive(:pending?).and_return(false)
      allow(job).to receive(:cancel!)

      result = described_class.cancel(job)

      expect(result).to be true
      expect(job).to have_received(:cancel!)
    end

    it 'cancels pending job' do
      job = double('GenerationJob')
      allow(job).to receive(:running?).and_return(false)
      allow(job).to receive(:pending?).and_return(true)
      allow(job).to receive(:cancel!)

      result = described_class.cancel(job)

      expect(result).to be true
    end

    it 'returns false for completed job' do
      job = double('GenerationJob')
      allow(job).to receive(:running?).and_return(false)
      allow(job).to receive(:pending?).and_return(false)

      result = described_class.cancel(job)

      expect(result).to be false
    end
  end

  describe '.models_available?' do
    before do
      allow(Generators::MissionBrainstormService).to receive(:models_available?).and_return({
        creative_a: true,
        creative_b: true
      })
      allow(Generators::MissionSynthesisService).to receive(:available?).and_return(true)
      allow(AIProviderService).to receive(:provider_available?).and_return(true)
    end

    it 'returns availability status' do
      result = described_class.models_available?

      expect(result[:available]).to be true
      expect(result[:models]).to have_key(:brainstorm_a)
      expect(result[:models]).to have_key(:synthesis)
      expect(result[:models]).to have_key(:builder)
    end
  end

  describe 'LOCATION_MODES' do
    it 'includes expected modes' do
      expect(described_class::LOCATION_MODES).to include(:existing)
      expect(described_class::LOCATION_MODES).to include(:mission_specific)
      expect(described_class::LOCATION_MODES).to include(:reusable_asset)
    end
  end

  describe 'DIFFICULTY_TIERS' do
    it 'includes expected tiers' do
      expect(described_class::DIFFICULTY_TIERS).to include(:easy)
      expect(described_class::DIFFICULTY_TIERS).to include(:normal)
      expect(described_class::DIFFICULTY_TIERS).to include(:hard)
    end
  end

  describe 'SETTINGS' do
    it 'includes fantasy' do
      expect(described_class::SETTINGS).to include(:fantasy)
    end
  end
end
