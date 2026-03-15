# frozen_string_literal: true

require 'faraday'

module LLM
  module Adapters
    # BaseAdapter provides common functionality for all provider adapters.
    #
    # Each adapter normalizes the provider's API to a common interface.
    #
    class BaseAdapter
      DEFAULT_TIMEOUT = GameConfig::LLM::TIMEOUTS[:default]
      DEFAULT_MAX_TOKENS = GameConfig::LLM::DEFAULTS[:max_tokens]
      DEFAULT_TEMPERATURE = GameConfig::LLM::TEMPERATURES[:default]

      class << self
        # Generate text completion
        # @param messages [Array<Hash>] conversation messages with :role and :content
        # @param model [String] model identifier
        # @param api_key [String] API key
        # @param options [Hash] generation options
        # @param json_mode [Boolean] force JSON output
        # @param tools [Array<Hash>, nil] tool definitions for function calling
        # @param response_schema [Hash, nil] structured output schema (Gemini-specific; nil for other adapters)
        # @return [Hash] { success: Boolean, text: String, data: Hash, error: String, tool_calls: Array }
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          raise NotImplementedError, 'Subclasses must implement generate'
        end

        # Generate image
        # @param prompt [String] image description
        # @param api_key [String] API key
        # @param options [Hash] image options
        # @return [Hash] { success: Boolean, url: String, data: Hash, error: String }
        def generate_image(prompt:, api_key:, options: {})
          raise NotImplementedError, 'Subclasses must implement generate_image'
        end

        protected

        # Create HTTP client for API requests
        # @param base_url [String] API base URL
        # @param api_key [String] API key
        # @param timeout [Integer] request timeout in seconds
        # @return [Faraday::Connection]
        def build_connection(base_url, api_key, timeout: DEFAULT_TIMEOUT)
          Faraday.new(url: base_url) do |conn|
            conn.request :json
            conn.response :json, content_type: /\bjson$/
            conn.adapter Faraday.default_adapter
            conn.options.timeout = timeout
            conn.options.open_timeout = GameConfig::LLM::TIMEOUTS[:http_open]
            yield conn if block_given?
          end
        end

        # Parse common options
        # @param options [Hash] raw options
        # @return [Hash] normalized options
        def normalize_options(options)
          # Support both symbol and string keys (string keys after JSONB round-trip)
          {
            max_tokens: options[:max_tokens] || options['max_tokens'] || DEFAULT_MAX_TOKENS,
            temperature: options[:temperature] || options['temperature'] || DEFAULT_TEMPERATURE,
            top_p: options[:top_p] || options['top_p'],
            stop: options[:stop] || options['stop']
          }.compact
        end

        # Validate and normalize canonical tool format
        # @param tools [Array<Hash>, nil] tool definitions
        # @return [Array<Hash>, nil] validated tools or nil
        def normalize_tools(tools)
          return nil if tools.nil? || (tools.is_a?(Array) && tools.empty?)

          tools.each do |tool|
            unless tool[:name] && tool[:parameters]
              raise ArgumentError, "Tool must have :name and :parameters keys"
            end
          end

          tools
        end

        # Build response hash with tool_calls
        # @param text [String, nil] any text content
        # @param tool_calls [Array<Hash>] extracted tool calls
        # @param data [Hash] full response data
        # @return [Hash]
        def tool_call_response(text, tool_calls, data = {})
          {
            success: true,
            text: text,
            tool_calls: tool_calls,
            data: data,
            error: nil
          }
        end

        # Build success response
        # @param text [String] generated text
        # @param data [Hash] full response data
        # @return [Hash]
        def success_response(text, data = {})
          {
            success: true,
            text: text,
            data: data,
            error: nil
          }
        end

        # Build error response
        # @param message [String] error message
        # @return [Hash]
        def error_response(message)
          {
            success: false,
            text: nil,
            data: {},
            error: message
          }
        end

        # Extract provider error message from a response body.
        # Falls back to status code when no nested message exists.
        # @param response [Faraday::Response]
        # @return [String]
        def provider_error_message(response)
          body = response.body
          body = {} unless body.is_a?(Hash)
          body.dig('error', 'message') || "HTTP #{response.status}"
        end

        # Standardized Faraday transport error message.
        # @param error [Faraday::Error]
        # @return [String]
        def faraday_error_message(error)
          "HTTP error: #{error.message}"
        end

        # Extract system message from messages array
        # @param messages [Array<Hash>] messages with :role and :content
        # @return [String, nil]
        def extract_system_message(messages)
          system = messages.find { |m| (m[:role] || m['role']) == 'system' }
          system && (system[:content] || system['content'])
        end

        # Filter out system messages
        # @param messages [Array<Hash>] messages
        # @return [Array<Hash>]
        def filter_system_messages(messages)
          messages.reject { |m| (m[:role] || m['role']) == 'system' }
        end
      end
    end
  end
end
