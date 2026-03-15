# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::OpenAIAdapter do
  let(:api_key) { 'test-api-key' }
  let(:model) { 'gpt-5-mini' }
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
    allow(Faraday).to receive(:new).and_yield(mock_connection).and_return(mock_connection)
    allow(mock_connection).to receive(:request)
    allow(mock_connection).to receive(:response)
    allow(mock_connection).to receive(:adapter)
    allow(mock_connection).to receive(:options).and_return(mock_options)
    allow(mock_connection).to receive(:headers).and_return(mock_headers)
  end

  describe '.generate' do
    let(:success_body) do
      {
        'choices' => [
          {
            'message' => { 'content' => 'Hello! How can I help you today?' },
            'finish_reason' => 'stop'
          }
        ],
        'model' => model,
        'usage' => { 'prompt_tokens' => 10, 'completion_tokens' => 8 }
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
      expect(result[:text]).to eq('Hello! How can I help you today?')
    end

    it 'includes raw response data' do
      result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      expect(result[:data]).to include('choices', 'model', 'usage')
    end

    it 'posts to chat/completions endpoint' do
      expect(mock_connection).to receive(:post).with('chat/completions', anything).and_return(mock_response)
      described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
    end

    it 'sends messages in request body' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:messages]).to be_an(Array)
        expect(body[:messages].length).to eq(2)
        mock_response
      end
      described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
    end

    context 'with GPT-5.4 model' do
      let(:model) { 'gpt-5.4' }

      it 'uses max_completion_tokens parameter' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).to have_key(:max_completion_tokens)
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      end
    end

    context 'with GPT-5 model' do
      let(:model) { 'gpt-5' }

      it 'uses max_completion_tokens parameter' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).to have_key(:max_completion_tokens)
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      end
    end

    context 'with o1 model' do
      let(:model) { 'o1-preview' }

      it 'uses max_completion_tokens parameter' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).to have_key(:max_completion_tokens)
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      end
    end

    context 'with o3 model' do
      let(:model) { 'o3-mini' }

      it 'uses max_completion_tokens parameter' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).to have_key(:max_completion_tokens)
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
      end
    end

    context 'with json_mode' do
      it 'sets response_format' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:response_format]).to eq({ type: 'json_object' })
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, json_mode: true, options: default_options)
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

      it 'sends stop' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:stop]).to eq(['END'])
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

      it 'sends tools with function wrapper in request body' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tools]).to be_an(Array)
          expect(body[:tools].first[:type]).to eq('function')
          expect(body[:tools].first[:function][:name]).to eq('extract_data')
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
      end

      it 'sets tool_choice to force specific function' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tool_choice]).to eq({ type: 'function', function: { name: 'extract_data' } })
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
      end

      it 'removes response_format when tools are present' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).not_to have_key(:response_format)
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, json_mode: true, tools: tools)
      end

      context 'when response contains tool_calls' do
        let(:tool_calls_body) do
          {
            'choices' => [{
              'message' => {
                'tool_calls' => [{
                  'id' => 'call_abc123',
                  'type' => 'function',
                  'function' => {
                    'name' => 'extract_data',
                    'arguments' => '{"name": "Test Room"}'
                  }
                }]
              },
              'finish_reason' => 'tool_calls'
            }]
          }
        end

        before do
          allow(mock_response).to receive(:body).and_return(tool_calls_body)
        end

        it 'returns tool_calls with parsed arguments' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options, tools: tools)
          expect(result[:success]).to be true
          expect(result[:tool_calls]).to be_an(Array)
          expect(result[:tool_calls].first[:id]).to eq('call_abc123')
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
        allow(mock_response).to receive(:status).and_return(429)
        allow(mock_response).to receive(:body).and_return({ 'error' => { 'message' => 'Rate limit exceeded' } })
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Rate limit exceeded')
      end
    end

    context 'when connection times out' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::TimeoutError.new('timeout'))
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end
  end

  describe '.generate_image' do
    let(:success_body) do
      {
        'data' => [
          { 'url' => 'https://example.com/image.png' }
        ]
      }
    end
    let(:image_options) { { timeout: 120 } }

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response with URL' do
      result = described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
      expect(result[:success]).to be true
      expect(result[:url]).to eq('https://example.com/image.png')
    end

    it 'posts to images/generations endpoint' do
      expect(mock_connection).to receive(:post).with('images/generations', anything).and_return(mock_response)
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
    end

    it 'uses dall-e-3 by default' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('dall-e-3')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
    end

    it 'uses default size' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:size]).to eq('1024x1024')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
    end

    it 'uses custom model' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('dall-e-2')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options.merge(model: 'dall-e-2'))
    end

    it 'uses custom size' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:size]).to eq('512x512')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options.merge(size: '512x512'))
    end

    it 'sends quality option' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:quality]).to eq('hd')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options.merge(quality: 'hd'))
    end

    it 'sends style option' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:style]).to eq('vivid')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options.merge(style: 'vivid'))
    end

    context 'when API returns error' do
      before do
        allow(mock_response).to receive(:success?).and_return(false)
        allow(mock_response).to receive(:status).and_return(400)
        allow(mock_response).to receive(:body).and_return({ 'error' => { 'message' => 'Invalid prompt' } })
      end

      it 'returns error response' do
        result = described_class.generate_image(prompt: 'test', api_key: api_key, options: image_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid prompt')
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns error response' do
        result = described_class.generate_image(prompt: 'test', api_key: api_key, options: image_options)
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end
  end

  describe 'constants' do
    it 'has BASE_URL' do
      expect(described_class::BASE_URL).to eq('https://api.openai.com/v1')
    end
  end
end
