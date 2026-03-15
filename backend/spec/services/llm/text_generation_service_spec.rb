# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::TextGenerationService do
  let(:prompt) { 'Tell me a story' }
  let(:api_key) { 'test-api-key' }
  let(:model) { 'claude-haiku-4-5' }

  before do
    allow(AIProviderService).to receive(:primary_provider).and_return('anthropic')
    allow(AIProviderService).to receive(:api_key_for).with('anthropic').and_return(api_key)
  end

  describe '.generate' do
    let(:success_result) do
      {
        success: true,
        text: 'Once upon a time...',
        data: { 'usage' => { 'tokens' => 100 } },
        error: nil
      }
    end

    before do
      allow(LLM::Adapters::AnthropicAdapter).to receive(:generate).and_return(success_result)
    end

    it 'returns successful response' do
      result = described_class.generate(prompt: prompt)
      expect(result[:success]).to be true
      expect(result[:text]).to eq('Once upon a time...')
    end

    it 'uses primary provider by default' do
      expect(LLM::Adapters::AnthropicAdapter).to receive(:generate)
      described_class.generate(prompt: prompt)
    end

    it 'builds messages with user prompt' do
      expect(LLM::Adapters::AnthropicAdapter).to receive(:generate) do |args|
        expect(args[:messages]).to include(hash_including(role: 'user', content: prompt))
        success_result
      end
      described_class.generate(prompt: prompt)
    end

    context 'with system prompt in options' do
      it 'includes system message' do
        expect(LLM::Adapters::AnthropicAdapter).to receive(:generate) do |args|
          expect(args[:messages].first).to eq({ role: 'system', content: 'You are helpful' })
          success_result
        end
        described_class.generate(prompt: prompt, options: { system_prompt: 'You are helpful' })
      end
    end

    context 'with pre-built messages' do
      let(:messages) do
        [
          { role: 'user', content: 'Hello' },
          { role: 'assistant', content: 'Hi there!' },
          { role: 'user', content: 'How are you?' }
        ]
      end

      it 'uses pre-built messages directly' do
        expect(LLM::Adapters::AnthropicAdapter).to receive(:generate) do |args|
          expect(args[:messages]).to eq(messages)
          success_result
        end
        described_class.generate(prompt: prompt, options: { messages: messages })
      end

      it 'adds system prompt to pre-built messages' do
        expect(LLM::Adapters::AnthropicAdapter).to receive(:generate) do |args|
          expect(args[:messages].first).to eq({ role: 'system', content: 'System' })
          expect(args[:messages].length).to eq(4)
          success_result
        end
        described_class.generate(prompt: prompt, options: { messages: messages, system_prompt: 'System' })
      end
    end

    context 'with json_mode' do
      it 'passes json_mode to adapter' do
        expect(LLM::Adapters::AnthropicAdapter).to receive(:generate) do |args|
          expect(args[:json_mode]).to be true
          success_result
        end
        described_class.generate(prompt: prompt, json_mode: true)
      end
    end

    context 'with specific provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('openai').and_return('openai-key')
        allow(LLM::Adapters::OpenAIAdapter).to receive(:generate).and_return(success_result)
      end

      it 'uses specified provider' do
        expect(LLM::Adapters::OpenAIAdapter).to receive(:generate)
        described_class.generate(prompt: prompt, provider: 'openai')
      end
    end

    context 'with google_gemini provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('google_gemini').and_return('gemini-key')
        allow(LLM::Adapters::GeminiAdapter).to receive(:generate).and_return(success_result)
      end

      it 'uses Gemini adapter' do
        expect(LLM::Adapters::GeminiAdapter).to receive(:generate)
        described_class.generate(prompt: prompt, provider: 'google_gemini')
      end
    end

    context 'with openrouter provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('openrouter').and_return('or-key')
        allow(LLM::Adapters::OpenRouterAdapter).to receive(:generate).and_return(success_result)
      end

      it 'uses OpenRouter adapter' do
        expect(LLM::Adapters::OpenRouterAdapter).to receive(:generate)
        described_class.generate(prompt: prompt, provider: 'openrouter')
      end
    end

    context 'when no provider configured' do
      before do
        allow(AIProviderService).to receive(:primary_provider).and_return(nil)
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No AI provider configured')
      end
    end

    context 'when no API key for provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('anthropic').and_return(nil)
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No API key for anthropic')
      end
    end

    context 'with unknown provider' do
      before do
        allow(AIProviderService).to receive(:api_key_for).with('unknown').and_return('some-key')
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt, provider: 'unknown')
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Unknown provider: unknown')
      end
    end

    context 'when Faraday error occurs' do
      before do
        allow(LLM::Adapters::AnthropicAdapter).to receive(:generate).and_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to include('HTTP error')
      end
    end

    context 'when JSON parse error occurs' do
      before do
        allow(LLM::Adapters::AnthropicAdapter).to receive(:generate).and_raise(JSON::ParserError.new('unexpected token'))
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to include('JSON parse error')
      end
    end

    context 'when unexpected error occurs' do
      before do
        allow(LLM::Adapters::AnthropicAdapter).to receive(:generate).and_raise(StandardError.new('Something went wrong'))
      end

      it 'returns error response' do
        result = described_class.generate(prompt: prompt)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unexpected error')
      end
    end
  end

  describe '.adapter_for' do
    it 'returns AnthropicAdapter for anthropic' do
      expect(described_class.adapter_for('anthropic')).to eq(LLM::Adapters::AnthropicAdapter)
    end

    it 'returns OpenAIAdapter for openai' do
      expect(described_class.adapter_for('openai')).to eq(LLM::Adapters::OpenAIAdapter)
    end

    it 'returns GeminiAdapter for google_gemini' do
      expect(described_class.adapter_for('google_gemini')).to eq(LLM::Adapters::GeminiAdapter)
    end

    it 'returns OpenRouterAdapter for openrouter' do
      expect(described_class.adapter_for('openrouter')).to eq(LLM::Adapters::OpenRouterAdapter)
    end

    it 'returns nil for unknown provider' do
      expect(described_class.adapter_for('unknown')).to be_nil
    end
  end
end
