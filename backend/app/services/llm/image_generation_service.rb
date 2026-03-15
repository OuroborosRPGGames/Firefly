# frozen_string_literal: true

require 'base64'
require 'fileutils'

module LLM
  # ImageGenerationService handles synchronous image generation.
  #
  # Supports multiple models with automatic fallback:
  # - Default: gemini-3.1-flash-image-preview (fast, good quality)
  # - High Quality: gemini-3-pro-image-preview (best quality, slower)
  # - Fallback: bytedance-seed/seedream-4.5 via OpenRouter (when Gemini rejects)
  #
  class ImageGenerationService
    DEFAULT_SIZE = '1024x1024'
    DEFAULT_QUALITY = 'standard'

    # Image generation model tiers
    MODEL_TIERS = {
      default: { provider: 'google_gemini', model: 'gemini-3.1-flash-image-preview' },
      high_quality: { provider: 'google_gemini', model: 'gemini-3-pro-image-preview' },
      openai: { provider: 'openai', model: 'gpt-image-1' },
      fallback: { provider: 'openrouter', model: 'bytedance-seed/seedream-4.5' }
    }.freeze

    class << self
      # Generate an image with automatic fallback on rejection
      # @param prompt [String] image description
      # @param options [Hash] image options
      #   - :size [String] image size (1024x1024, 1792x1024, 1024x1792)
      #   - :quality [String] quality level (standard, hd, high_quality)
      #   - :style [String] style (vivid, natural)
      #   - :model [String] specific model to use (overrides tier selection)
      #   - :provider [String] specific provider to use (overrides tier selection)
      #   - :tier [Symbol] model tier (:default, :high_quality)
      #   - :allow_fallback [Boolean] whether to try fallback on rejection (default: true)
      # @return [Hash] { success: Boolean, url: String, local_url: String, data: Hash, error: String, model_used: String }
      def generate(prompt:, options: {})
        allow_fallback = options.fetch(:allow_fallback, true)
        tier = options[:tier]&.to_sym || :default

        # Use high_quality tier if quality option is 'high_quality' or 'hd'
        tier = :high_quality if %w[high_quality hd].include?(options[:quality])

        # If provider/model explicitly specified, use them directly (no fallback)
        if options[:provider] && options[:model]
          return generate_with_model(prompt, options[:provider], options[:model], options)
        end

        # Build model chain based on tier
        models_to_try = build_model_chain(tier, allow_fallback)

        # Try each model in the chain
        last_error = nil
        models_to_try.each do |model_config|
          provider = model_config[:provider]
          model = model_config[:model]

          # Skip if provider not available
          unless AIProviderService.provider_available?(provider)
            last_error = "Provider #{provider} not available"
            next
          end

          result = generate_with_model(prompt, provider, model, options)

          # If successful, return the result with model info
          if result[:success]
            result[:model_used] = model
            result[:provider_used] = provider
            return result
          end

          # Check if this is a rejection vs a temporary error
          if prompt_rejected?(result[:error])
            # Content rejection - try fallback
            last_error = result[:error]
            warn "[ImageGenerationService] #{model} rejected prompt, trying fallback..." if ENV['DEBUG']
            next
          else
            # Other error (rate limit, API down, etc.) - try fallback
            last_error = result[:error]
            warn "[ImageGenerationService] #{model} error: #{result[:error]}, trying fallback..." if ENV['DEBUG']
            next
          end
        end

        # All models failed
        error_response("All image generation models failed. Last error: #{last_error}")
      rescue Faraday::Error => e
        error_response("HTTP error: #{e.message}")
      rescue StandardError => e
        error_response("Unexpected error: #{e.message}")
      end

      # Generate image with a specific model (no fallback)
      # @param prompt [String] image description
      # @param provider [String] provider name
      # @param model [String] model name
      # Check if image generation is available (any configured provider)
      # @return [Boolean]
      def available?
        MODEL_TIERS.values.any? { |config| AIProviderService.provider_available?(config[:provider]) }
      end

      # @param options [Hash] additional options
      # @return [Hash]
      def generate_with_model(prompt, provider, model, options = {})
        api_key = AIProviderService.api_key_for(provider)
        return error_response("No API key for #{provider}") unless api_key

        adapter = adapter_for(provider)
        return error_response("Unknown provider: #{provider}") unless adapter

        # Normalize options with specific model
        opts = normalize_options(options.merge(model: model), provider)

        # Generate image
        result = adapter.generate_image(
          prompt: prompt,
          api_key: api_key,
          options: opts
        )

        # Handle result based on response type
        if result[:success]
          if result[:base64_data]
            # Gemini returns base64 - save to storage and set URL
            saved_url = save_base64_image(result[:base64_data], result[:mime_type])
            if saved_url
              result[:url] ||= saved_url
              result[:local_url] = saved_url
            end
          elsif result[:url]
            # URL-based providers - download to local storage
            local_path = ImageDownloader.download(result[:url])
            result[:local_url] = local_path if local_path
          end
          result[:model_used] = model
          result[:provider_used] = provider
        end

        result
      end

      private

      # Build the chain of models to try based on tier
      # @param tier [Symbol] :default or :high_quality
      # @param allow_fallback [Boolean] whether to include fallback model
      # @return [Array<Hash>] array of { provider:, model: } hashes
      def build_model_chain(tier, allow_fallback)
        chain = []

        # Add primary model based on tier
        primary = MODEL_TIERS[tier] || MODEL_TIERS[:default]
        chain << primary

        # For high_quality, also try default tier before fallback
        if tier == :high_quality
          chain << MODEL_TIERS[:default]
        end

        # Add fallback if allowed
        if allow_fallback
          chain << MODEL_TIERS[:fallback]
        end

        chain.uniq
      end

      # Check if an error message indicates prompt rejection (content policy violation)
      # @param error_message [String, nil] the error message
      # @return [Boolean]
      def prompt_rejected?(error_message)
        return false unless error_message

        rejection_indicators = [
          'safety', 'content policy', 'rejected', 'inappropriate',
          'not allowed', 'prohibited', 'blocked', 'policy violation',
          'harmful', 'offensive', 'violates', 'cannot generate'
        ]

        error_lower = error_message.downcase
        rejection_indicators.any? { |indicator| error_lower.include?(indicator) }
      end

      # Select the best available provider for image generation (legacy method)
      def select_provider
        # Prefer Gemini for image generation, then OpenAI, then OpenRouter
        if AIProviderService.provider_available?('google_gemini')
          'google_gemini'
        elsif AIProviderService.provider_available?('openai')
          'openai'
        elsif AIProviderService.provider_available?('openrouter')
          'openrouter'
        end
      end

      def adapter_for(provider)
        case provider
        when 'google_gemini'
          Adapters::GeminiAdapter
        when 'openai'
          Adapters::OpenAIAdapter
        when 'openrouter'
          Adapters::OpenRouterAdapter
        end
      end

      def normalize_options(options, provider)
        dims = options[:dimensions] # { width:, height: } from AIBattleMapGeneratorService

        case provider
        when 'google_gemini'
          opts = {
            model: options[:model] || 'gemini-3.1-flash-image-preview'
          }
          # Gemini uses aspect_ratio string; convert dimensions if no explicit ratio
          if options[:aspect_ratio]
            opts[:aspect_ratio] = options[:aspect_ratio]
          elsif dims
            opts[:aspect_ratio] = dimensions_to_gemini_ratio(dims)
          end
          opts[:reference_image] = options[:reference_image] if options[:reference_image]
          opts[:thinking_level] = options[:thinking_level] if options[:thinking_level]
          opts[:thinking_budget] = options[:thinking_budget] unless options[:thinking_budget].nil?
          opts
        when 'openai'
          model = options[:model] || 'dall-e-3'
          gpt_image = model.start_with?('gpt-image')

          opts = {
            model: model,
            n: options[:n] || 1
          }

          if gpt_image
            opts[:size] = dims ? dimensions_to_gpt_image_size(dims) : '1024x1024'
            opts[:quality] = map_quality_to_gpt_image(options[:quality])
            opts[:output_format] = 'png'
          else
            opts[:size] = dims ? dimensions_to_dalle_size(dims) : (options[:size] || DEFAULT_SIZE)
            opts[:quality] = options[:quality] || DEFAULT_QUALITY
            opts[:style] = options[:style]
          end

          opts.compact
        else
          {
            model: options[:model] || 'dall-e-3',
            size: dims ? dimensions_to_dalle_size(dims) : (options[:size] || DEFAULT_SIZE),
            quality: options[:quality] || DEFAULT_QUALITY,
            style: options[:style],
            n: options[:n] || 1
          }.compact
        end
      end

      # Convert dimensions to nearest Gemini aspect ratio
      def dimensions_to_gemini_ratio(dims)
        ratio = dims[:width].to_f / dims[:height]
        if ratio > 1.5 then '16:9'
        elsif ratio > 1.2 then '4:3'
        elsif ratio < 0.67 then '9:16'
        elsif ratio < 0.83 then '3:4'
        else '1:1'
        end
      end

      # Convert dimensions to nearest gpt-image-1 size
      def dimensions_to_gpt_image_size(dims)
        ratio = dims[:width].to_f / dims[:height]
        if ratio > 1.2 then '1536x1024'
        elsif ratio < 0.83 then '1024x1536'
        else '1024x1024'
        end
      end

      # Convert dimensions to nearest DALL-E size
      def dimensions_to_dalle_size(dims)
        ratio = dims[:width].to_f / dims[:height]
        if ratio > 1.2 then '1792x1024'
        elsif ratio < 0.83 then '1024x1792'
        else '1024x1024'
        end
      end

      # Map quality setting to gpt-image-1 format
      def map_quality_to_gpt_image(quality)
        case quality
        when 'hd', 'high_quality', 'high' then 'high'
        when 'low' then 'low'
        else 'medium'
        end
      end

      # Save base64 image data to storage (R2 or local)
      # @param base64_data [String] base64 encoded image data
      # @param mime_type [String] image MIME type (e.g., 'image/png')
      # @return [String, nil] public URL or nil on failure
      def save_base64_image(base64_data, mime_type)
        return nil unless base64_data

        # Determine extension from mime type
        extension = case mime_type
                    when 'image/png' then 'png'
                    when 'image/jpeg', 'image/jpg' then 'jpg'
                    when 'image/webp' then 'webp'
                    when 'image/gif' then 'gif'
                    else 'png'
                    end

        # Generate storage key
        date_path = Time.now.strftime('%Y/%m')
        filename = "#{SecureRandom.hex(12)}.#{extension}"
        key = "generated/#{date_path}/#{filename}"

        # Decode and upload via CloudStorageService
        data = Base64.decode64(base64_data)
        CloudStorageService.upload(data, key, content_type: mime_type || 'image/png')
      rescue StandardError => e
        warn "[ImageGenerationService] Failed to save image: #{e.message}"
        nil
      end

      def error_response(message)
        { success: false, url: nil, local_url: nil, data: {}, error: message }
      end
    end
  end
end
