# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::OpenRouterAdapter do
  let(:api_key) { 'sk-or-test-api-key' }
  let(:model) { 'anthropic/claude-haiku-4-5' }
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

    context 'with OpenAI model and json_mode' do
      let(:openai_model) { 'openai/gpt-5.4' }

      it 'sets response_format for native JSON mode' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:response_format]).to eq({ type: 'json_object' })
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: openai_model,
          api_key: api_key,
          json_mode: true,
          options: default_options
        )
      end
    end

    context 'with non-OpenAI model and json_mode' do
      let(:anthropic_model) { 'anthropic/claude-haiku-4-5' }

      it 'adds JSON instruction to system message' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          system_msg = body[:messages].find { |m| m[:role] == 'system' }
          expect(system_msg[:content]).to include('valid JSON only')
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: anthropic_model,
          api_key: api_key,
          json_mode: true,
          options: default_options
        )
      end

      it 'adds system message if none exists' do
        no_system_messages = [{ role: 'user', content: 'Hello' }]

        expect(mock_connection).to receive(:post) do |_endpoint, body|
          has_system = body[:messages].any? { |m| m[:role] == 'system' }
          expect(has_system).to be true
          mock_response
        end
        described_class.generate(
          messages: no_system_messages,
          model: anthropic_model,
          api_key: api_key,
          json_mode: true,
          options: default_options
        )
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
        described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
      end

      it 'sets tool_choice to force specific function' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tool_choice]).to eq({ type: 'function', function: { name: 'extract_data' } })
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
      end

      it 'removes response_format when tools are present with json_mode' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body).not_to have_key(:response_format)
          mock_response
        end
        described_class.generate(messages: [{ role: 'user', content: 'test' }], model: 'openai/gpt-5.4', api_key: api_key, json_mode: true, tools: tools)
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
          result = described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
          expect(result[:success]).to be true
          expect(result[:tool_calls]).to be_an(Array)
          expect(result[:tool_calls].first[:id]).to eq('call_abc123')
          expect(result[:tool_calls].first[:name]).to eq('extract_data')
          expect(result[:tool_calls].first[:arguments]).to eq({ 'name' => 'Test Room' })
        end

        it 'returns nil text when tool call is present' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
          expect(result[:text]).to be_nil
        end
      end
    end

    context 'when API returns error' do
      before do
        allow(mock_response).to receive(:success?).and_return(false)
        allow(mock_response).to receive(:status).and_return(400)
        allow(mock_response).to receive(:body).and_return({ 'error' => { 'message' => 'Model not found' } })
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key, options: default_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Model not found')
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
    let(:image_model) { 'bytedance-seed/seedream-4.5' }
    let(:base64_image) { 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' }
    let(:success_body) do
      {
        'choices' => [
          {
            'message' => {
              'content' => '',
              'images' => [
                { 'image_url' => { 'url' => "data:image/png;base64,#{base64_image}" } }
              ]
            }
          }
        ]
      }
    end
    let(:image_options) { { timeout: 120 } }

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response with base64 data' do
      result = described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
      expect(result[:success]).to be true
      expect(result[:base64_data]).to eq(base64_image)
      expect(result[:mime_type]).to eq('image/png')
    end

    it 'uses default image model' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('bytedance-seed/seedream-4.5')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
    end

    it 'uses custom image model' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body[:model]).to eq('custom/image-model')
        mock_response
      end
      described_class.generate_image(
        prompt: 'A cat',
        api_key: api_key,
        options: image_options.merge(model: 'custom/image-model')
      )
    end

    context 'with regular URL response' do
      let(:url_body) do
        {
          'choices' => [
            {
              'message' => {
                'content' => '',
                'images' => [
                  { 'image_url' => { 'url' => 'https://example.com/image.png' } }
                ]
              }
            }
          ]
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(url_body)
      end

      it 'returns URL directly' do
        result = described_class.generate_image(prompt: 'A cat', api_key: api_key, options: image_options)
        expect(result[:success]).to be true
        expect(result[:url]).to eq('https://example.com/image.png')
        expect(result[:base64_data]).to be_nil
      end
    end

    context 'when no image generated' do
      let(:text_body) do
        {
          'choices' => [
            {
              'message' => {
                'content' => 'I cannot generate that type of image',
                'images' => nil
              }
            }
          ]
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(text_body)
      end

      it 'returns error with text response' do
        result = described_class.generate_image(prompt: 'Bad request', api_key: api_key, options: image_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('I cannot generate that type of image')
      end
    end

    context 'when response has no message' do
      let(:empty_body) { { 'choices' => [{}] } }

      before do
        allow(mock_response).to receive(:body).and_return(empty_body)
      end

      it 'returns error' do
        result = described_class.generate_image(prompt: 'test', api_key: api_key, options: image_options)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No message in response')
      end
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
      expect(described_class::BASE_URL).to eq('https://openrouter.ai/api/v1')
    end
  end
end
