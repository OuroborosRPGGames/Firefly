# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::MissionBrainstormService do
  describe '.brainstorm' do
    let(:description) { 'A heist to steal the Duke\'s ledger from his fortified manor' }
    let(:setting) { :fantasy }
    let(:seed_terms) { %w[mysterious intrigue noble] }

    let(:request_a) do
      double('LLMRequest',
             status: 'completed',
             response_text: 'Creative brainstorm output A...',
             error_message: nil,
             parsed_context: { 'model_key' => 'creative_a' })
    end
    let(:request_b) do
      double('LLMRequest',
             status: 'completed',
             response_text: 'Creative brainstorm output B...',
             error_message: nil,
             parsed_context: { 'model_key' => 'creative_b' })
    end
    let(:batch) do
      double('LlmBatch', wait!: true, results: [request_a, request_b])
    end

    before do
      allow(LLM::Client).to receive(:batch_submit).and_return(batch)
    end

    it 'returns success with outputs from both models' do
      result = described_class.brainstorm(
        description: description,
        setting: setting,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:outputs]).to be_a(Hash)
      expect(result[:outputs][:creative_a]).to include('brainstorm output A')
      expect(result[:outputs][:creative_b]).to include('brainstorm output B')
    end

    it 'includes seed terms in result' do
      result = described_class.brainstorm(
        description: description,
        setting: setting,
        seed_terms: seed_terms
      )

      expect(result[:seed_terms]).to eq(seed_terms)
    end

    it 'submits batch with correct request structure' do
      expect(LLM::Client).to receive(:batch_submit).with(
        array_including(
          hash_including(provider: 'openrouter', context: { model_key: 'creative_a' }),
          hash_including(provider: 'openai', context: { model_key: 'creative_b' })
        )
      ).and_return(batch)

      described_class.brainstorm(
        description: description,
        setting: setting,
        seed_terms: seed_terms
      )
    end

    it 'handles LLM failures gracefully' do
      failed_request = double('LLMRequest',
                              status: 'failed',
                              response_text: nil,
                              error_message: 'API error',
                              parsed_context: { 'model_key' => 'creative_a' })
      failed_batch = double('LlmBatch', wait!: true, results: [failed_request, request_b])
      allow(LLM::Client).to receive(:batch_submit).and_return(failed_batch)

      result = described_class.brainstorm(
        description: description,
        setting: setting,
        seed_terms: seed_terms
      )

      expect(result[:errors]).to include(/API error/)
    end
  end

  describe '.brainstorm_single' do
    let(:description) { 'A rescue mission into goblin territory' }
    let(:setting) { :fantasy }

    before do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: 'Single model brainstorm output...'
      })
    end

    it 'uses specified model key' do
      result = described_class.brainstorm_single(
        description: description,
        setting: setting,
        model_key: :creative_a
      )

      expect(result[:success]).to be true
      expect(result[:output]).to be_a(String)
    end

    it 'returns error for invalid model key' do
      result = described_class.brainstorm_single(
        description: description,
        setting: setting,
        model_key: :invalid_key
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('Unknown model key')
    end
  end

  describe '.models_available?' do
    it 'returns hash with model availability' do
      allow(AIProviderService).to receive(:provider_available?).and_return(true)

      result = described_class.models_available?

      expect(result).to be_a(Hash)
      expect(result).to have_key(:creative_a)
      expect(result).to have_key(:creative_b)
    end
  end

  describe 'BRAINSTORM_MODELS' do
    it 'includes creative_a and creative_b' do
      expect(described_class::BRAINSTORM_MODELS).to have_key(:creative_a)
      expect(described_class::BRAINSTORM_MODELS).to have_key(:creative_b)
    end

    it 'has valid provider configurations' do
      described_class::BRAINSTORM_MODELS.each do |key, config|
        expect(config).to have_key(:provider)
        expect(config).to have_key(:model)
      end
    end
  end
end
