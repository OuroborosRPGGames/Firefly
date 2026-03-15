# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::EmbeddingService do
  let(:text) { 'Hello world' }
  let(:api_key) { 'pa-test-api-key' }
  let(:embedding_data) { Array.new(1024) { rand } }

  before do
    allow(GameSetting).to receive(:get).with('voyage_api_key').and_return(api_key)
    allow(GameSetting).to receive(:get).with('default_embedding_model').and_return(nil)
  end

  describe '.generate' do
    let(:success_result) do
      {
        success: true,
        embedding: embedding_data,
        embeddings: [embedding_data],
        dimensions: 1024,
        model: 'voyage-3-large',
        error: nil
      }
    end

    before do
      allow(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).and_return(success_result)
    end

    it 'returns successful response' do
      result = described_class.generate(text: text)
      expect(result[:success]).to be true
      expect(result[:embedding]).to eq(embedding_data)
    end

    it 'calls VoyageAdapter with correct parameters' do
      expect(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).with(
        input: text,
        api_key: api_key,
        model: 'voyage-3-large',
        input_type: 'document'
      )
      described_class.generate(text: text)
    end

    it 'uses query input_type when specified' do
      expect(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).with(
        hash_including(input_type: 'query')
      )
      described_class.generate(text: text, input_type: 'query')
    end

    it 'uses custom model when specified' do
      expect(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).with(
        hash_including(model: 'voyage-3.5-lite')
      )
      described_class.generate(text: text, model: 'voyage-3.5-lite')
    end

    context 'with nil text' do
      it 'returns error response' do
        result = described_class.generate(text: nil)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Text is required')
      end
    end

    context 'with empty text' do
      it 'returns error response' do
        result = described_class.generate(text: '')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Text is required')
      end
    end

    context 'when API key not configured' do
      before do
        allow(GameSetting).to receive(:get).with('voyage_api_key').and_return(nil)
      end

      it 'returns error response' do
        result = described_class.generate(text: text)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Voyage API key not configured')
      end
    end

    context 'when API key is empty' do
      before do
        allow(GameSetting).to receive(:get).with('voyage_api_key').and_return('')
      end

      it 'returns error response' do
        result = described_class.generate(text: text)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Voyage API key not configured')
      end
    end

    context 'with custom default model in settings' do
      before do
        allow(GameSetting).to receive(:get).with('default_embedding_model').and_return('voyage-3.5')
      end

      it 'uses model from settings' do
        expect(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).with(
          hash_including(model: 'voyage-3.5')
        )
        described_class.generate(text: text)
      end
    end
  end

  describe '.generate_batch' do
    let(:texts) { ['Hello', 'World', 'Test'] }
    let(:batch_result) do
      {
        success: true,
        embedding: embedding_data,
        embeddings: [embedding_data, embedding_data, embedding_data],
        dimensions: 1024,
        model: 'voyage-3-large',
        error: nil
      }
    end

    before do
      allow(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).and_return(batch_result)
    end

    it 'returns successful response with multiple embeddings' do
      result = described_class.generate_batch(texts: texts)
      expect(result[:success]).to be true
      expect(result[:embeddings].length).to eq(3)
    end

    it 'calls VoyageAdapter with texts array' do
      expect(LLM::Adapters::VoyageAdapter).to receive(:generate_embedding).with(
        input: texts,
        api_key: api_key,
        model: 'voyage-3-large',
        input_type: 'document'
      )
      described_class.generate_batch(texts: texts)
    end

    context 'with nil texts' do
      it 'returns error response' do
        result = described_class.generate_batch(texts: nil)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Texts array is required')
      end
    end

    context 'with empty texts array' do
      it 'returns error response' do
        result = described_class.generate_batch(texts: [])
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Texts array is required')
      end
    end

    context 'with non-array texts' do
      it 'returns error response' do
        result = described_class.generate_batch(texts: 'not an array')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Texts must be an array')
      end
    end
  end

  describe '.available?' do
    context 'when API key is configured' do
      it 'returns true' do
        expect(described_class.available?).to be true
      end
    end

    context 'when API key is nil' do
      before do
        allow(GameSetting).to receive(:get).with('voyage_api_key').and_return(nil)
      end

      it 'returns false' do
        expect(described_class.available?).to be false
      end
    end

    context 'when API key is empty' do
      before do
        allow(GameSetting).to receive(:get).with('voyage_api_key').and_return('')
      end

      it 'returns false' do
        expect(described_class.available?).to be false
      end
    end
  end

  describe '.default_model' do
    context 'when no setting configured' do
      it 'returns DEFAULT_MODEL constant' do
        expect(described_class.default_model).to eq('voyage-3-large')
      end
    end

    context 'when setting is configured' do
      before do
        allow(GameSetting).to receive(:get).with('default_embedding_model').and_return('voyage-3.5')
      end

      it 'returns model from settings' do
        expect(described_class.default_model).to eq('voyage-3.5')
      end
    end
  end

  describe '.default_dimensions' do
    it 'returns dimensions for default model' do
      expect(described_class.default_dimensions).to eq(1024)
    end

    context 'with lite model as default' do
      before do
        allow(GameSetting).to receive(:get).with('default_embedding_model').and_return('voyage-3.5-lite')
      end

      it 'returns dimensions for lite model' do
        expect(described_class.default_dimensions).to eq(512)
      end
    end
  end

  describe '.dimensions_for' do
    it 'returns dimensions for specified model' do
      expect(described_class.dimensions_for('voyage-3-large')).to eq(1024)
      expect(described_class.dimensions_for('voyage-3.5-lite')).to eq(512)
    end
  end
end
