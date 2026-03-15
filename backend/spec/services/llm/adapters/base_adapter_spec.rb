# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LLM::Adapters::BaseAdapter do
  describe '.generate' do
    it 'raises NotImplementedError' do
      expect {
        described_class.generate(
          messages: [{ role: 'user', content: 'Hello' }],
          model: 'test',
          api_key: 'key'
        )
      }.to raise_error(NotImplementedError, 'Subclasses must implement generate')
    end
  end

  describe '.generate_image' do
    it 'raises NotImplementedError' do
      expect {
        described_class.generate_image(prompt: 'test', api_key: 'key')
      }.to raise_error(NotImplementedError, 'Subclasses must implement generate_image')
    end
  end

  describe 'protected methods' do
    describe '.build_connection' do
      it 'creates Faraday connection' do
        conn = described_class.send(:build_connection, 'https://example.com', 'key')
        expect(conn).to be_a(Faraday::Connection)
      end

      it 'configures JSON request/response' do
        conn = described_class.send(:build_connection, 'https://example.com', 'key')
        expect(conn.builder.handlers).to include(Faraday::Request::Json)
      end

      it 'sets default timeout' do
        conn = described_class.send(:build_connection, 'https://example.com', 'key')
        expect(conn.options.timeout).to eq(GameConfig::LLM::TIMEOUTS[:default])
      end

      it 'uses custom timeout' do
        conn = described_class.send(:build_connection, 'https://example.com', 'key', timeout: 120)
        expect(conn.options.timeout).to eq(120)
      end

      it 'yields connection for customization' do
        yielded = nil
        described_class.send(:build_connection, 'https://example.com', 'key') do |c|
          yielded = c
          c.headers['X-Custom'] = 'value'
        end
        expect(yielded).to be_a(Faraday::Connection)
        expect(yielded.headers['X-Custom']).to eq('value')
      end
    end

    describe '.normalize_options' do
      it 'returns default max_tokens' do
        result = described_class.send(:normalize_options, {})
        expect(result[:max_tokens]).to eq(GameConfig::LLM::DEFAULTS[:max_tokens])
      end

      it 'returns default temperature' do
        result = described_class.send(:normalize_options, {})
        expect(result[:temperature]).to eq(GameConfig::LLM::TEMPERATURES[:default])
      end

      it 'uses provided max_tokens' do
        result = described_class.send(:normalize_options, { max_tokens: 1000 })
        expect(result[:max_tokens]).to eq(1000)
      end

      it 'uses provided temperature' do
        result = described_class.send(:normalize_options, { temperature: 0.5 })
        expect(result[:temperature]).to eq(0.5)
      end

      it 'includes top_p when provided' do
        result = described_class.send(:normalize_options, { top_p: 0.9 })
        expect(result[:top_p]).to eq(0.9)
      end

      it 'includes stop when provided' do
        result = described_class.send(:normalize_options, { stop: ['END'] })
        expect(result[:stop]).to eq(['END'])
      end

      it 'excludes nil values' do
        result = described_class.send(:normalize_options, { top_p: nil })
        expect(result).not_to have_key(:top_p)
      end
    end

    describe '.success_response' do
      it 'returns success hash' do
        result = described_class.send(:success_response, 'Generated text', { model: 'test' })
        expect(result[:success]).to be true
        expect(result[:text]).to eq('Generated text')
        expect(result[:data]).to eq({ model: 'test' })
        expect(result[:error]).to be_nil
      end

      it 'works with empty data' do
        result = described_class.send(:success_response, 'Text')
        expect(result[:data]).to eq({})
      end
    end

    describe '.error_response' do
      it 'returns error hash' do
        result = described_class.send(:error_response, 'Something went wrong')
        expect(result[:success]).to be false
        expect(result[:text]).to be_nil
        expect(result[:data]).to eq({})
        expect(result[:error]).to eq('Something went wrong')
      end
    end

    describe '.extract_system_message' do
      it 'extracts system message content' do
        messages = [
          { role: 'system', content: 'You are helpful' },
          { role: 'user', content: 'Hello' }
        ]
        result = described_class.send(:extract_system_message, messages)
        expect(result).to eq('You are helpful')
      end

      it 'returns nil when no system message' do
        messages = [{ role: 'user', content: 'Hello' }]
        result = described_class.send(:extract_system_message, messages)
        expect(result).to be_nil
      end
    end

    describe '.filter_system_messages' do
      it 'removes system messages' do
        messages = [
          { role: 'system', content: 'System' },
          { role: 'user', content: 'Hello' },
          { role: 'assistant', content: 'Hi' }
        ]
        result = described_class.send(:filter_system_messages, messages)
        expect(result.length).to eq(2)
        expect(result.none? { |m| m[:role] == 'system' }).to be true
      end

      it 'returns empty array when all are system' do
        messages = [{ role: 'system', content: 'Only system' }]
        result = described_class.send(:filter_system_messages, messages)
        expect(result).to eq([])
      end
    end
  end

  describe 'constants' do
    it 'has DEFAULT_TIMEOUT' do
      expect(described_class::DEFAULT_TIMEOUT).to eq(GameConfig::LLM::TIMEOUTS[:default])
    end

    it 'has DEFAULT_MAX_TOKENS' do
      expect(described_class::DEFAULT_MAX_TOKENS).to eq(GameConfig::LLM::DEFAULTS[:max_tokens])
    end

    it 'has DEFAULT_TEMPERATURE' do
      expect(described_class::DEFAULT_TEMPERATURE).to eq(GameConfig::LLM::TEMPERATURES[:default])
    end
  end
end
