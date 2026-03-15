# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::GeminiAdapter do
  let(:api_key) { 'test-api-key' }
  let(:model) { 'gemini-3-flash-preview' }
  let(:messages) do
    [
      { role: 'system', content: 'You are helpful' },
      { role: 'user', content: 'Hello' }
    ]
  end

  let(:mock_connection) { instance_double(Faraday::Connection) }
  let(:mock_response) { instance_double(Faraday::Response) }
  let(:mock_options) { OpenStruct.new(timeout: 60) }

  before do
    # Gemini creates connection without using build_connection
    allow(Faraday).to receive(:new).and_return(mock_connection)
    allow(mock_connection).to receive(:request)
    allow(mock_connection).to receive(:response)
    allow(mock_connection).to receive(:adapter)
    allow(mock_connection).to receive(:options).and_return(mock_options)
  end

  describe '.generate' do
    let(:success_body) do
      {
        'candidates' => [
          {
            'content' => {
              'parts' => [{ 'text' => 'Hello! How can I help you today?' }]
            }
          }
        ]
      }
    end

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response' do
      result = described_class.generate(messages: messages, model: model, api_key: api_key)
      expect(result[:success]).to be true
      expect(result[:text]).to eq('Hello! How can I help you today?')
    end

    it 'includes raw response data' do
      result = described_class.generate(messages: messages, model: model, api_key: api_key)
      expect(result[:data]).to include('candidates')
    end

    it 'posts to generateContent endpoint with API key' do
      expect(mock_connection).to receive(:post) do |endpoint, _body|
        expect(endpoint).to include("models/#{model}:generateContent")
        expect(endpoint).to include("key=#{api_key}")
        mock_response
      end
      described_class.generate(messages: messages, model: model, api_key: api_key)
    end

    it 'converts messages to Gemini format with system prepended' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        contents = body[:contents]
        # System message prepended to first user message
        expect(contents.first[:parts].first[:text]).to include('You are helpful')
        expect(contents.first[:parts].first[:text]).to include('Hello')
        mock_response
      end
      described_class.generate(messages: messages, model: model, api_key: api_key)
    end

    it 'maps assistant role to model role' do
      messages_with_assistant = [
        { role: 'user', content: 'Hi' },
        { role: 'assistant', content: 'Hello' },
        { role: 'user', content: 'How are you?' }
      ]

      expect(mock_connection).to receive(:post) do |_endpoint, body|
        contents = body[:contents]
        expect(contents[1][:role]).to eq('model')
        mock_response
      end
      described_class.generate(messages: messages_with_assistant, model: model, api_key: api_key)
    end

    context 'with json_mode' do
      it 'adds JSON instruction to system prompt' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          text = body[:contents].first[:parts].first[:text]
          expect(text).to include('valid JSON only')
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, json_mode: true)
      end
    end

    context 'with multimodal content' do
      let(:multimodal_messages) do
        [
          {
            role: 'user',
            content: [
              { type: 'text', text: 'What is in this image?' },
              { type: 'image', mime_type: 'image/png', data: 'base64data' }
            ]
          }
        ]
      end

      it 'handles multimodal messages' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          parts = body[:contents].first[:parts]
          expect(parts.length).to eq(2)
          expect(parts.first[:text]).to include('What is in this image')
          expect(parts.last[:inlineData]).to be_a(Hash)
          mock_response
        end
        described_class.generate(messages: multimodal_messages, model: model, api_key: api_key)
      end
    end

    context 'with custom options' do
      it 'sends maxOutputTokens' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body.dig(:generationConfig, :maxOutputTokens)).to eq(1000)
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: { max_tokens: 1000 }
        )
      end

      it 'sends temperature' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body.dig(:generationConfig, :temperature)).to eq(0.5)
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: { temperature: 0.5 }
        )
      end

      it 'sends stopSequences' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body.dig(:generationConfig, :stopSequences)).to eq(['END'])
          mock_response
        end
        described_class.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: { stop: ['END'] }
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

      it 'sends functionDeclarations in request body' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tools]).to be_an(Array)
          declarations = body[:tools].first[:functionDeclarations]
          expect(declarations.first[:name]).to eq('extract_data')
          expect(declarations.first[:parameters]).to include(type: 'object')
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
      end

      it 'sets tool_config to force function calling' do
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          expect(body[:tool_config]).to eq({ function_calling_config: { mode: 'ANY' } })
          mock_response
        end
        described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
      end

      context 'when response contains functionCall' do
        let(:function_call_body) do
          {
            'candidates' => [{
              'content' => {
                'parts' => [{
                  'functionCall' => {
                    'name' => 'extract_data',
                    'args' => { 'name' => 'Test Room' }
                  }
                }]
              }
            }]
          }
        end

        before do
          allow(mock_response).to receive(:body).and_return(function_call_body)
        end

        it 'returns tool_calls in response' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
          expect(result[:success]).to be true
          expect(result[:tool_calls]).to be_an(Array)
          expect(result[:tool_calls].first[:name]).to eq('extract_data')
          expect(result[:tool_calls].first[:arguments]).to eq({ 'name' => 'Test Room' })
        end

        it 'returns nil text when tool call is present' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
          expect(result[:text]).to be_nil
        end
      end

      context 'when functionCall args is JSON string' do
        let(:string_args_body) do
          {
            'candidates' => [{
              'content' => {
                'parts' => [{
                  'functionCall' => {
                    'name' => 'extract_data',
                    'args' => '{"name": "Parsed Room"}'
                  }
                }]
              }
            }]
          }
        end

        before do
          allow(mock_response).to receive(:body).and_return(string_args_body)
        end

        it 'parses JSON string arguments' do
          result = described_class.generate(messages: messages, model: model, api_key: api_key, tools: tools)
          expect(result[:tool_calls].first[:arguments]).to eq({ 'name' => 'Parsed Room' })
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
        result = described_class.generate(messages: messages, model: model, api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid request')
      end
    end

    context 'when connection fails' do
      before do
        allow(mock_connection).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns error response' do
        result = described_class.generate(messages: messages, model: model, api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end
  end

  describe '.generate_image' do
    let(:image_model) { 'gemini-3.1-flash-image-preview' }
    let(:success_body) do
      {
        'candidates' => [
          {
            'content' => {
              'parts' => [
                {
                  'inlineData' => {
                    'mimeType' => 'image/png',
                    'data' => 'base64imagedata'
                  }
                }
              ]
            }
          }
        ]
      }
    end

    before do
      allow(mock_response).to receive(:success?).and_return(true)
      allow(mock_response).to receive(:body).and_return(success_body)
      allow(mock_connection).to receive(:post).and_return(mock_response)
    end

    it 'returns successful response with base64 data' do
      result = described_class.generate_image(prompt: 'A cat', api_key: api_key)
      expect(result[:success]).to be true
      expect(result[:base64_data]).to eq('base64imagedata')
      expect(result[:mime_type]).to eq('image/png')
    end

    it 'uses gemini-3.1-flash-image-preview model by default' do
      expect(mock_connection).to receive(:post) do |endpoint, _body|
        expect(endpoint).to include('gemini-3.1-flash-image-preview')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key)
    end

    it 'uses custom model' do
      expect(mock_connection).to receive(:post) do |endpoint, _body|
        expect(endpoint).to include('custom-image-model')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: { model: 'custom-image-model' })
    end

    it 'sends aspect_ratio option' do
      expect(mock_connection).to receive(:post) do |_endpoint, body|
        expect(body.dig(:generationConfig, :imageConfig, :aspectRatio)).to eq('16:9')
        mock_response
      end
      described_class.generate_image(prompt: 'A cat', api_key: api_key, options: { aspect_ratio: '16:9' })
    end

    context 'with snake_case response format' do
      let(:success_body) do
        {
          'candidates' => [
            {
              'content' => {
                'parts' => [
                  {
                    'inline_data' => {
                      'mime_type' => 'image/jpeg',
                      'data' => 'snakecasedata'
                    }
                  }
                ]
              }
            }
          ]
        }
      end

      it 'handles snake_case format' do
        result = described_class.generate_image(prompt: 'A cat', api_key: api_key)
        expect(result[:success]).to be true
        expect(result[:base64_data]).to eq('snakecasedata')
      end
    end

    context 'when no image generated' do
      let(:text_response) do
        {
          'candidates' => [
            {
              'content' => {
                'parts' => [{ 'text' => 'I cannot generate that image' }]
              }
            }
          ]
        }
      end

      before do
        allow(mock_response).to receive(:body).and_return(text_response)
      end

      it 'returns error with text response' do
        result = described_class.generate_image(prompt: 'Bad request', api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('I cannot generate that image')
      end
    end

    context 'when API returns error' do
      before do
        allow(mock_response).to receive(:success?).and_return(false)
        allow(mock_response).to receive(:status).and_return(400)
        allow(mock_response).to receive(:body).and_return({ 'error' => { 'message' => 'Invalid prompt' } })
      end

      it 'returns error response' do
        result = described_class.generate_image(prompt: 'test', api_key: api_key)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid prompt')
      end
    end

    context 'with reference_image' do
      it 'includes image part before text in request body' do
        ref_data = Base64.strict_encode64('fake_png_data')
        expect(mock_connection).to receive(:post) do |_endpoint, body|
          parts = body.dig(:contents, 0, :parts)
          expect(parts.length).to eq(2)
          expect(parts[0]).to have_key(:inlineData)
          expect(parts[0][:inlineData][:mimeType]).to eq('image/png')
          expect(parts[0][:inlineData][:data]).to eq(ref_data)
          expect(parts[1]).to have_key(:text)
          mock_response
        end

        described_class.generate_image(
          prompt: 'Convert this blueprint',
          api_key: api_key,
          options: {
            reference_image: { data: ref_data, mime_type: 'image/png' }
          }
        )
      end

      it 'returns successful response' do
        ref_data = Base64.strict_encode64('fake_png_data')
        result = described_class.generate_image(
          prompt: 'Convert this blueprint',
          api_key: api_key,
          options: {
            reference_image: { data: ref_data, mime_type: 'image/png' }
          }
        )
        expect(result[:success]).to be true
      end
    end
  end

  describe 'constants' do
    it 'has BASE_URL' do
      expect(described_class::BASE_URL).to eq('https://generativelanguage.googleapis.com/v1beta')
    end
  end
end
