# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::AnthropicAdapter do
  let(:api_key) { 'test-api-key' }
  let(:model) { 'claude-haiku-4-5-20251001' }
  let(:messages) do
    [
      { role: 'system', content: 'You are helpful' },
      { role: 'user', content: 'Hello' }
    ]
  end
  # Always pass timeout to avoid DEFAULT_TIMEOUT constant lookup issues
  let(:default_options) { { timeout: 60 } }

  let(:mock_connection) { instance_double(Faraday::Connection) }
  let(:mock_response) { instance_double(Faraday::Response) }
  let(:mock_options) { OpenStruct.new(timeout: 60, open_timeout: 10) }
  let(:mock_headers) { {} }

  before do
    # Mock Faraday.new to return our mock connection
    allow(Faraday).to receive(:new).and_yield(mock_connection).and_return(mock_connection)
    allow(mock_connection).to receive(:request)
    allow(mock_connection).to receive(:response)
    allow(mock_connection).to receive(:adapter)
    allow(mock_connection).to receive(:options).and_return(mock_options)
    allow(mock_connection).to receive(:headers).and_return(mock_headers)
  end

  describe '.resolve_model' do
    it 'resolves claude-opus-4-6 alias' do
      result = described_class.resolve_model('claude-opus-4-6')
      expect(result).to eq('claude-opus-4-6')
    end

    it 'resolves claude-sonnet-4-6 alias' do
      result = described_class.resolve_model('claude-sonnet-4-6')
      expect(result).to eq('claude-sonnet-4-6')
    end

    it 'resolves claude-haiku-4-5 alias' do
      result = described_class.resolve_model('claude-haiku-4-5')
      expect(result).to eq('claude-haiku-4-5-20251001')
    end

    it 'returns model as-is when not an alias' do
      result = described_class.resolve_model('claude-haiku-4-5-20251001')
      expect(result).to eq('claude-haiku-4-5-20251001')
    end
  end

  describe '.generate' do
    let(:success_body) do
      {
        'content' => [{ 'type' => 'text', 'text' => 'Hello! How can I help?' }],
        'model' => model,
        'usage' => { 'input_tokens' => 10, 'output_tokens' => 8 }
      }
    end

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response' do
      result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      expect(result[:success]).to be true
      expect(result[:text]).to eq('Hello! How can I help?')
    end

    it 'includes raw response data' do
      result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      expect(result[:data]).to include('content', 'model', 'usage')
    end

    it 'posts to v1/messages endpoint' do
      expect(mock_connection).to receive(:post).with('v1/messages', anything).and_return(mock_response)
      described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
    end

    it 'includes system message separately' do
      expect(mock_connection).to receive(:post).with('v1/messages', hash_including(system: 'You are helpful')).and_return(mock_response)
      described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
    end

    it 'filters system messages from messages array' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:messages]).to eq([{ role: 'user', content: 'Hello' }])
        mock_response
      end
      described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
    end

    context 'with json_mode' do
      it 'adds JSON instruction to system prompt' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:system]).to include('valid JSON only')
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, json_mode: true, options: default_options)
      end
    end

    context 'with partial_assistant option' do
      before do
        allow(mock_response).to receive(:body).and_return({
          'content' => [{ 'type' => 'text', 'text' => ' continued response' }]
        })
      end

      it 'adds partial assistant message' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:messages].last).to eq({ role: 'assistant', content: 'Here is my response:' })
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: default_options.merge(partial_assistant: 'Here is my response:')
        )
      end

      it 'prepends partial_assistant to response text' do
        result = described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: default_options.merge(partial_assistant: 'Prefix: ')
        )
        expect(result[:text]).to start_with('Prefix: ')
      end
    end

    context 'with custom options' do
      it 'sends temperature' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:temperature]).to eq(0.5)
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: default_options.merge(temperature: 0.5)
        )
      end

      it 'sends top_p' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:top_p]).to eq(0.9)
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: default_options.merge(top_p: 0.9)
        )
      end

      it 'sends stop_sequences' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:stop_sequences]).to eq(['END'])
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: default_options.merge(stop: ['END'])
        )
      end
    end

    context 'with tools' do
      let(:tools) do
        [{
          name: 'extract_data',
          description: 'Extract structured data',
          parameters: {
            type: 'object',
            properties: { name: { type: 'string' } },
            required: ['name']
          }
        }]
      end

      it 'sends tools with input_schema in request body' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tools]).to be_an(Array)
          expect(body[:tools].first[:name]).to eq('extract_data')
          expect(body[:tools].first[:input_schema]).to include(type: 'object')
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
      end

      it 'sets tool_choice to force specific tool' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tool_choice]).to eq({ type: 'tool', name: 'extract_data' })
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
      end

      context 'when response contains tool_use block' do
        let(:tool_use_body) do
          {
            'content' => [
              { 'type' => 'tool_use', 'id' => 'toolu_123', 'name' => 'extract_data', 'input' => { 'name' => 'Test Room' } }
            ],
            'model' => model,
            'stop_reason' => 'tool_use'
          }
        end

        before do
          allow(mock_response).to receive(:body).and_return(tool_use_body)
        end

        it 'returns tool_calls in response' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
          expect(result[:success]).to be true
          expect(result[:tool_calls]).to be_an(Array)
          expect(result[:tool_calls].first[:id]).to eq('toolu_123')
          expect(result[:tool_calls].first[:name]).to eq('extract_data')
          expect(result[:tool_calls].first[:arguments]).to eq({ 'name' => 'Test Room' })
        end

        it 'returns nil text when tool call is present' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
          expect(result[:text]).to be_nil
        end
      end
    end

    context 'when API returns error' do
      before do
        allow(mock_response).to receive(:success?).and_return(false)
        allow(mock_response).to receive(:status).and_return(400)
        allow(mock_response).to receive(:body).and_return({ 'error' => { 'message' => 'Invalid request' } })
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid request')
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end
  end

  describe '.generate_image' do
    it 'returns error (not supported)' do
      result = described_class.generate_image(prompt: 'A cat', api_key: api_key)
      expect(result[:success]).to be false
      expect(result[:error]).to include('does not support image generation')
    end
  end

  describe 'constants' do
    it 'has BASE_URL' do
      expect(described_class::BASE_URL).to eq('https://api.anthropic.com')
    end

    it 'has API_VERSION' do
      expect(described_class::API_VERSION).to eq('2023-06-01')
    end

    it 'has MODEL_ALIASES' do
      expect(described_class::MODEL_ALIASES).to be_a(Hash)
      expect(described_class::MODEL_ALIASES).to have_key('claude-opus-4-6')
    end
  end
end
