# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::VoyageAdapter do
  let(:api_key) { 'pa-test-api-key' }
  let(:model) { 'voyage-3-large' }
  let(:input) { 'Hello world' }

  let(:mock_connection) { instance_double(Faraday::Connection) }
  let(:mock_response) { instance_double(Faraday::Response) }
  let(:mock_options) { OpenStruct.new(timeout: 30, open_timeout: 10) }
  let(:mock_headers) { {} }

  before do
    allow(Faraday).to receive(:new).and_yield(mock_connection).and_return(mock_connection)
    allow(mock_connection).to receive(:request)
    allow(mock_connection).to receive(:response)
    allow(mock_connection).to receive(:adapter)
    allow(mock_connection).to receive(:options).and_return(mock_options)
    allow(mock_connection).to receive(:headers).and_return(mock_headers)
  end

  describe '.generate_embedding' do
    let(:embedding_data) { Array.new(1024) { rand } }
    let(:success_body) do
      {
        'data' => [
          { 'embedding' => embedding_data }
        ],
        'usage' => { 'total_tokens' => 3 }
      }
    end

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:success]).to be true
    end

    it 'returns embedding array' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:embedding]).to be_an(Array)
      expect(result[:embedding].length).to eq(1024)
    end

    it 'returns embeddings array for batch access' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:embeddings]).to be_an(Array)
      expect(result[:embeddings].length).to eq(1)
    end

    it 'returns dimensions' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:dimensions]).to eq(1024)
    end

    it 'returns model name' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:model]).to eq(model)
    end

    it 'returns usage data' do
      result = described_class.generate_embedding(input: input, api_key: api_key)
      expect(result[:usage]).to eq({ 'total_tokens' => 3 })
    end

    it 'posts to embeddings endpoint' do
      expect(mock_connection).to receive(:post).with('embeddings', anything).and_return(mock_response)
      described_class.generate_embedding(input: input, api_key: api_key)
    end

    it 'uses default model' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('voyage-3-large')
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key)
    end

    it 'uses custom model' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('voyage-3.5-lite')
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key, model: 'voyage-3.5-lite')
    end

    it 'sends input_type for query' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:input_type]).to eq('query')
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key, input_type: 'query')
    end

    it 'sends input_type for document' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:input_type]).to eq('document')
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key, input_type: 'document')
    end

    it 'ignores invalid input_type' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body).not_to have_key(:input_type)
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key, input_type: 'invalid')
    end

    it 'sends truncation option' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:truncation]).to eq(false)
        mock_response
      end
      described_class.generate_embedding(input: input, api_key: api_key, truncation: false)
    end

    context 'with batch input' do
      let(:batch_input) { ['Hello', 'World', 'Test'] }
      let(:batch_body) do
        {
          'data' => [
            { 'embedding' => Array.new(1024) { rand } },
            { 'embedding' => Array.new(1024) { rand } },
            { 'embedding' => Array.new(1024) { rand } }
          ],
          'usage' => { 'total_tokens' => 9 }
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(batch_body)
      end

      it 'returns multiple embeddings' do
        result = described_class.generate_embedding(input: batch_input, api_key: api_key)
        expect(result[:embeddings].length).to eq(3)
      end

      it 'returns first embedding as convenience accessor' do
        result = described_class.generate_embedding(input: batch_input, api_key: api_key)
        expect(result[:embedding]).to eq(result[:embeddings].first)
      end
    end

    context 'when API returns error' do
      before do
        allow(mock_response).to receive(:success?).and_return(false)
        allow(mock_response).to receive(:status).and_return(400)
        allow(mock_response).to receive(:body).and_return({ 'detail' => 'Invalid input' })
      end

      it 'returns error response' do
        result = described_class.generate_embedding(input: input, api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid input')
      end

      it 'returns nil embedding' do
        result = described_class.generate_embedding(input: input, api_key: api_key)
        expect(result[:embedding]).to be_nil
        expect(result[:embeddings]).to eq([])
      end
    end

    context 'when request times out' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::TimeoutError.new('timeout'))
      end

      it 'returns timeout error' do
        result = described_class.generate_embedding(input: input, api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Request timed out')
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns connection error' do
        result = described_class.generate_embedding(input: input, api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Connection failed')
      end
    end
  end

  describe '.generate' do
    it 'returns error (not supported)' do
      result = described_class.generate(
        messages: [{ role: 'user', content: 'Hello' }],
        model: 'voyage-3-large',
        api_key: api_key
      )
      expect(result[:success]).to be false
      expect(result[:error]).to include('does not support text generation')
    end
  end

  describe '.generate_image' do
    it 'returns error (not supported)' do
      result = described_class.generate_image(prompt: 'A cat', api_key: api_key)
      expect(result[:success]).to be false
      expect(result[:error]).to include('does not support image generation')
    end
  end

  describe '.dimensions_for' do
    it 'returns 1024 for voyage-3-large' do
      expect(described_class.dimensions_for('voyage-3-large')).to eq(1024)
    end

    it 'returns 1024 for voyage-3.5' do
      expect(described_class.dimensions_for('voyage-3.5')).to eq(1024)
    end

    it 'returns 512 for voyage-3.5-lite' do
      expect(described_class.dimensions_for('voyage-3.5-lite')).to eq(512)
    end

    it 'returns 1024 for voyage-code-3' do
      expect(described_class.dimensions_for('voyage-code-3')).to eq(1024)
    end

    it 'returns 1024 for unknown model' do
      expect(described_class.dimensions_for('unknown-model')).to eq(1024)
    end
  end

  describe '.valid_model?' do
    it 'returns true for valid models' do
      %w[voyage-3-large voyage-3.5 voyage-3.5-lite voyage-code-3 voyage-law-2 voyage-finance-2].each do |m|
        expect(described_class.valid_model?(m)).to be true
      end
    end

    it 'returns false for invalid model' do
      expect(described_class.valid_model?('invalid-model')).to be false
    end
  end

  describe 'constants' do
    it 'has BASE_URL' do
      expect(described_class::BASE_URL).to eq('https://api.voyageai.com/v1')
    end

    it 'has DEFAULT_MODEL' do
      expect(described_class::DEFAULT_MODEL).to eq('voyage-3-large')
    end

    it 'has MODEL_DIMENSIONS' do
      expect(described_class::MODEL_DIMENSIONS).to be_a(Hash)
      expect(described_class::MODEL_DIMENSIONS).to have_key('voyage-3-large')
    end

    it 'has INPUT_TYPES' do
      expect(described_class::INPUT_TYPES).to eq(%w[document query])
    end
  end
end
