# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AIProviderService do
  # Helper to set API keys for testing
  def set_api_key(provider, key)
    setting = GameSetting.first(key: "#{provider}_api_key")
    if setting
      setting.update(value: key)
    else
      GameSetting.create(key: "#{provider}_api_key", value: key, value_type: 'string', category: 'ai')
    end
  end

  def clear_api_keys
    AIProviderService::PROVIDERS.each do |provider|
      setting = GameSetting.first(key: "#{provider}_api_key")
      setting&.update(value: nil)
    end
  end

  before { clear_api_keys }

  describe '.api_key_for' do
    it 'returns nil when no key is configured' do
      expect(AIProviderService.api_key_for('anthropic')).to be_nil
    end

    it 'returns the configured key' do
      set_api_key('anthropic', 'sk-ant-test-key')
      expect(AIProviderService.api_key_for('anthropic')).to eq('sk-ant-test-key')
    end
  end

  describe '.provider_available?' do
    it 'returns false when no key is configured' do
      expect(AIProviderService.provider_available?('anthropic')).to be false
    end

    it 'returns true when key is configured' do
      set_api_key('anthropic', 'sk-ant-test-key')
      expect(AIProviderService.provider_available?('anthropic')).to be true
    end

    it 'returns false for empty key' do
      set_api_key('anthropic', '')
      expect(AIProviderService.provider_available?('anthropic')).to be false
    end
  end

  describe '.available_providers' do
    it 'returns empty array when no providers are configured' do
      expect(AIProviderService.available_providers).to eq([])
    end

    it 'returns list of configured providers' do
      set_api_key('anthropic', 'sk-ant-test')
      set_api_key('openai', 'sk-test')
      expect(AIProviderService.available_providers).to include('anthropic', 'openai')
    end

    it 'respects provider order' do
      set_api_key('openai', 'sk-test')
      set_api_key('anthropic', 'sk-ant-test')
      # Default order is anthropic first
      expect(AIProviderService.available_providers.first).to eq('anthropic')
    end
  end

  describe '.primary_provider' do
    it 'returns nil when no providers are configured' do
      expect(AIProviderService.primary_provider).to be_nil
    end

    it 'returns the first available provider' do
      set_api_key('anthropic', 'sk-ant-test')
      expect(AIProviderService.primary_provider).to eq('anthropic')
    end

    it 'respects provider preference order' do
      set_api_key('openai', 'sk-test')
      set_api_key('google_gemini', 'key')
      # OpenAI comes before Gemini in default order
      expect(AIProviderService.primary_provider).to eq('openai')
    end
  end

  describe '.any_available?' do
    it 'returns false when no providers are configured' do
      expect(AIProviderService.any_available?).to be false
    end

    it 'returns true when at least one provider is configured' do
      set_api_key('openrouter', 'sk-or-test')
      expect(AIProviderService.any_available?).to be true
    end
  end

  describe '.fallback_to_non_llm?' do
    it 'returns true when no providers are available' do
      expect(AIProviderService.fallback_to_non_llm?).to be true
    end

    it 'returns false when providers are available' do
      set_api_key('anthropic', 'sk-ant-test')
      expect(AIProviderService.fallback_to_non_llm?).to be false
    end
  end

  describe '.config_for' do
    before { set_api_key('anthropic', 'sk-ant-test') }

    it 'returns provider configuration hash' do
      config = AIProviderService.config_for('anthropic')
      expect(config[:provider]).to eq('anthropic')
      expect(config[:api_key]).to eq('sk-ant-test')
      expect(config[:base_url]).to eq('https://api.anthropic.com')
      expect(config[:default_model]).to eq('claude-sonnet-4-6')
      expect(config[:available]).to be true
    end

    it 'shows unavailable for unconfigured provider' do
      config = AIProviderService.config_for('openai')
      expect(config[:available]).to be false
      expect(config[:api_key]).to be_nil
    end
  end

  describe '.with_fallback' do
    it 'returns nil when no providers are available' do
      result = AIProviderService.with_fallback { |config| config }
      expect(result).to be_nil
    end

    it 'yields config to block' do
      set_api_key('anthropic', 'sk-ant-test')
      result = AIProviderService.with_fallback do |config|
        config[:provider]
      end
      expect(result).to eq('anthropic')
    end

    it 'tries next provider on failure' do
      set_api_key('anthropic', 'sk-ant-test')
      set_api_key('openai', 'sk-test')

      call_count = 0
      result = AIProviderService.with_fallback do |config|
        call_count += 1
        raise StandardError, 'Failed' if config[:provider] == 'anthropic'

        config[:provider]
      end

      expect(call_count).to eq(2)
      expect(result).to eq('openai')
    end

    it 'respects preferred provider' do
      set_api_key('anthropic', 'sk-ant-test')
      set_api_key('openai', 'sk-test')

      result = AIProviderService.with_fallback(preferred: 'openai') do |config|
        config[:provider]
      end
      expect(result).to eq('openai')
    end
  end

  describe '.status_summary' do
    it 'returns summary hash' do
      summary = AIProviderService.status_summary
      expect(summary).to have_key(:any_available)
      expect(summary).to have_key(:primary_provider)
      expect(summary).to have_key(:providers)
      expect(summary).to have_key(:preference_order)
    end

    it 'shows provider status correctly' do
      set_api_key('anthropic', 'sk-ant-test')
      summary = AIProviderService.status_summary

      anthropic_status = summary[:providers].find { |p| p[:name] == 'anthropic' }
      expect(anthropic_status[:available]).to be true
      expect(anthropic_status[:configured]).to be true

      openai_status = summary[:providers].find { |p| p[:name] == 'openai' }
      expect(openai_status[:available]).to be false
      expect(openai_status[:configured]).to be false
    end
  end

  describe '.set_provider_order' do
    it 'sets custom provider order' do
      AIProviderService.set_provider_order(%w[openai anthropic])
      expect(AIProviderService.provider_order.first).to eq('openai')
    end
  end
end
