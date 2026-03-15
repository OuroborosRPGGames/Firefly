# frozen_string_literal: true

# AIProviderService handles AI API key management and provider fallback logic.
#
# Manages API keys for multiple AI providers (Anthropic, OpenAI, Google Gemini, OpenRouter)
# and provides fallback logic when a preferred provider is unavailable.
#
# Usage:
#   # Check if any AI provider is available
#   AIProviderService.any_available?
#
#   # Get the primary available provider
#   AIProviderService.primary_provider  # => 'anthropic'
#
#   # Get API key for a specific provider
#   AIProviderService.api_key_for('openai')
#
#   # Get a client for the primary provider
#   client, provider = AIProviderService.get_client
#
class AIProviderService
  # Supported AI providers in default preference order
  PROVIDERS = %w[anthropic openai google_gemini openrouter replicate].freeze

  # Provider-specific base URLs for API calls
  PROVIDER_URLS = {
    'anthropic' => 'https://api.anthropic.com',
    'openai' => 'https://api.openai.com/v1',
    'google_gemini' => 'https://generativelanguage.googleapis.com/v1beta',
    'openrouter' => 'https://openrouter.ai/api/v1',
    'replicate' => 'https://api.replicate.com/v1'
  }.freeze

  # Default models for each provider
  DEFAULT_MODELS = {
    'anthropic' => 'claude-sonnet-4-6',
    'openai' => 'gpt-5.4',
    'google_gemini' => 'gemini-3-flash-preview',
    'openrouter' => 'deepseek/deepseek-v3.2',
    'replicate' => 'philz1337x/clarity-upscaler'
  }.freeze

  # Image generation models with quality tiers
  IMAGE_MODELS = {
    'default' => { provider: 'google_gemini', model: 'gemini-3.1-flash-image-preview' },
    'high_quality' => { provider: 'google_gemini', model: 'gemini-3-pro-image-preview' },
    'fallback' => { provider: 'openrouter', model: 'bytedance-seed/seedream-4.5' }
  }.freeze

  # All available models by provider for reference
  AVAILABLE_MODELS = {
    'google_gemini' => %w[
      gemini-3-pro-preview
      gemini-3-pro-image-preview
      gemini-3-flash-preview
      gemini-3.1-flash-image-preview
      gemini-3-flash-preview
      gemini-3.1-flash-lite-preview
    ],
    'anthropic' => %w[
      claude-opus-4-6
      claude-sonnet-4-6
      claude-haiku-4-5
    ],
    'openai' => %w[
      gpt-5.4
      gpt-5-mini
    ],
    'openrouter' => %w[
      bytedance-seed/seedream-4.5
      deepseek/deepseek-v3.2
      moonshotai/kimi-k2-0905
    ],
    'replicate' => %w[
      philz1337x/clarity-upscaler
      batouresearch/magic-image-refiner
    ]
  }.freeze

  class << self
    # Get the API key for a specific provider
    # @param provider [String] the provider name
    # @return [String, nil] the API key or nil if not configured
    def api_key_for(provider)
      key = GameSetting.get("#{provider}_api_key")
      return nil if key.nil? || key.empty?

      key
    end

    # Check if a provider has a configured API key
    # @param provider [String] the provider name
    # @return [Boolean]
    def provider_available?(provider)
      key = api_key_for(provider)
      !key.nil? && !key.empty?
    end

    # Get the configured provider preference order
    # Falls back to default order if not configured
    # @return [Array<String>]
    def provider_order
      order = GameSetting.get('ai_provider_order')
      return PROVIDERS if order.nil? || order.empty?

      # Handle JSON string
      order = JSON.parse(order) if order.is_a?(String)
      order.is_a?(Array) ? order : PROVIDERS
    rescue JSON::ParserError
      PROVIDERS
    end

    # Set the provider preference order
    # @param order [Array<String>] array of provider names
    def set_provider_order(order)
      GameSetting.set('ai_provider_order', order.to_json, type: 'json')
    end

    # Get list of available providers (with configured API keys) in preference order
    # @return [Array<String>]
    def available_providers
      provider_order.select { |p| provider_available?(p) }
    end

    # Get the first available provider (primary)
    # @return [String, nil]
    def primary_provider
      available_providers.first
    end

    # Check if any AI provider is configured
    # @return [Boolean]
    def any_available?
      available_providers.any?
    end

    # Check if we should fall back to non-LLM functionality
    # @return [Boolean]
    def fallback_to_non_llm?
      !any_available?
    end

    # Get API key for the primary available provider
    # @return [String, nil]
    def primary_api_key
      provider = primary_provider
      provider ? api_key_for(provider) : nil
    end

    # Get configuration for a specific provider
    # @param provider [String] the provider name
    # @return [Hash] provider configuration
    def config_for(provider)
      {
        provider: provider,
        api_key: api_key_for(provider),
        base_url: PROVIDER_URLS[provider],
        default_model: DEFAULT_MODELS[provider],
        available: provider_available?(provider)
      }
    end

    # Get configuration for the primary provider
    # @return [Hash, nil]
    def primary_config
      provider = primary_provider
      provider ? config_for(provider) : nil
    end

    # Attempt to use a provider, falling back if it fails
    # @param preferred [String, nil] optional preferred provider
    # @yield [config] block to execute with provider config
    # @return result of block or nil if all providers fail
    def with_fallback(preferred: nil)
      providers = preferred && provider_available?(preferred) ?
        [preferred] + available_providers.reject { |p| p == preferred } :
        available_providers

      providers.each do |provider|
        config = config_for(provider)
        begin
          result = yield(config)
          return result if result
        rescue StandardError => e
          # Log error and try next provider
          log_provider_error(provider, e)
          next
        end
      end

      nil
    end

    # Get provider status summary for admin dashboard
    # @return [Hash]
    def status_summary
      {
        any_available: any_available?,
        primary_provider: primary_provider,
        providers: PROVIDERS.map do |provider|
          key = api_key_for(provider)
          {
            name: provider,
            available: provider_available?(provider),
            configured: !key.nil? && !key.empty?
          }
        end,
        preference_order: provider_order
      }
    end

    private

    def log_provider_error(provider, error)
      warn "[AIProviderService] Provider #{provider} failed: #{error.message}" if ENV['LOG_AI_PROVIDERS']
    end
  end
end
