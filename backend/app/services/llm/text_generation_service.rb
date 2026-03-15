# frozen_string_literal: true

require 'faraday'
require 'json'

module LLM
  # TextGenerationService handles synchronous text generation across providers.
  #
  # Uses provider adapters to normalize requests/responses between different APIs.
  #
  class TextGenerationService
    class << self
      # Generate text completion
      # @param prompt [String] the prompt to send
      # @param model [String, nil] specific model to use
      # @param provider [String, nil] specific provider to use
      # @param options [Hash] LLM options (max_tokens, temperature, etc.)
      # @param json_mode [Boolean] force JSON response format
      # @param tools [Array<Hash>, nil] tool definitions for function calling
      # @param conversation [LLMConversation, nil] existing conversation for context
      # @return [Hash] { success: Boolean, text: String, data: Hash, error: String, tool_calls: Array }
      def generate(prompt:, model: nil, provider: nil, options: {}, json_mode: false, tools: nil, conversation: nil)
        provider ||= AIProviderService.primary_provider
        return error_response('No AI provider configured') unless provider

        model ||= AIProviderService::DEFAULT_MODELS[provider]
        api_key = AIProviderService.api_key_for(provider)
        return error_response("No API key for #{provider}") unless api_key

        adapter = adapter_for(provider)
        return error_response("Unknown provider: #{provider}") unless adapter

        # Build messages array for conversation context
        messages = build_messages(prompt, conversation, options)

        # Execute request
        adapter.generate(
          messages: messages,
          model: model,
          api_key: api_key,
          options: options,
          json_mode: json_mode,
          tools: tools
        )
      rescue Faraday::Error => e
        error_response("HTTP error: #{e.message}")
      rescue JSON::ParserError => e
        error_response("JSON parse error: #{e.message}")
      rescue StandardError => e
        error_response("Unexpected error: #{e.message}")
      end

      # Get the appropriate adapter for a provider
      # @param provider [String] provider name
      # @return [Adapters::BaseAdapter, nil]
      def adapter_for(provider)
        case provider
        when 'anthropic'
          Adapters::AnthropicAdapter
        when 'openai'
          Adapters::OpenAIAdapter
        when 'google_gemini'
          Adapters::GeminiAdapter
        when 'openrouter'
          Adapters::OpenRouterAdapter
        end
      end

      private

      # Build messages array from prompt and optional conversation
      # @param prompt [String] current prompt
      # @param conversation [LLMConversation, nil] conversation for context
      # @param options [Hash] may contain system_prompt or messages
      # @return [Array<Hash>]
      def build_messages(prompt, conversation, options)
        # If pre-built messages are provided, use them directly
        # This allows callers to pass properly formatted user/assistant alternation
        if options[:messages].is_a?(Array) && !options[:messages].empty?
          messages = []

          # Add system prompt if provided
          if options[:system_prompt]
            messages << { role: 'system', content: options[:system_prompt] }
          end

          # Add the pre-built messages
          options[:messages].each do |msg|
            messages << { role: msg[:role], content: msg[:content] }
          end

          return messages
        end

        messages = []

        # Add system prompt if provided
        if options[:system_prompt]
          messages << { role: 'system', content: options[:system_prompt] }
        elsif conversation&.system_prompt && !conversation.system_prompt.empty?
          messages << { role: 'system', content: conversation.system_prompt }
        end

        # Add conversation history if present
        if conversation
          conversation.llm_messages.each do |msg|
            messages << { role: msg.role, content: msg.content }
          end
        end

        # Add current prompt as user message
        messages << { role: 'user', content: prompt }

        messages
      end

      def error_response(message)
        { success: false, text: nil, data: {}, tool_calls: [], error: message }
      end
    end
  end
end
