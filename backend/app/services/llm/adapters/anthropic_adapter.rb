# frozen_string_literal: true

require_relative 'base_adapter'

module LLM
  module Adapters
    # AnthropicAdapter handles API requests to Anthropic (Claude).
    #
    # Anthropic uses a different API format:
    # - System prompt is a separate parameter
    # - Messages have 'role' and 'content'
    # - Response is in content[0].text
    #
    class AnthropicAdapter < BaseAdapter
      BASE_URL = 'https://api.anthropic.com'
      API_VERSION = '2023-06-01'

      # Model ID aliases - map short names to full API model IDs
      MODEL_ALIASES = {
        'claude-opus-4-6' => 'claude-opus-4-6',
        'claude-sonnet-4-6' => 'claude-sonnet-4-6',
        'claude-haiku-4-5' => 'claude-haiku-4-5-20251001'
      }.freeze

      class << self
        # Resolve model alias to full model ID
        # @param model [String] model identifier (may be alias or full ID)
        # @return [String] full model ID
        def resolve_model(model)
          MODEL_ALIASES[model] || model
        end
        # Generate text completion via Anthropic Messages API
        # @param messages [Array<Hash>] conversation messages
        # @param model [String] model identifier (claude-haiku-4-5, etc.)
        # @param api_key [String] API key
        # @param options [Hash] generation options
        # @param json_mode [Boolean] force JSON output (prompt-based)
        # @return [Hash]
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          timeout = options[:timeout] || BaseAdapter::DEFAULT_TIMEOUT
          conn = build_connection(BASE_URL, api_key, timeout: timeout) do |c|
            c.headers['x-api-key'] = api_key
            c.headers['anthropic-version'] = API_VERSION
          end

          opts = normalize_options(options)

          # Extract system message (Anthropic handles it separately)
          system_prompt = extract_system_message(messages)
          filtered_messages = filter_system_messages(messages)

          # Native structured output via json_schema option (support both symbol and string keys after JSONB round-trip)
          json_schema = options[:json_schema] || options['json_schema']
          if json_mode && !json_schema
            # Fallback: prompt-based JSON enforcement when no schema provided
            json_instruction = "\n\nIMPORTANT: You MUST respond with valid JSON only. No markdown, no explanation, just the raw JSON object."
            system_prompt = system_prompt ? "#{system_prompt}#{json_instruction}" : json_instruction.strip
          end

          messages_array = filtered_messages.map { |m| { role: m[:role], content: m[:content] } }

          # Add partial assistant response if provided (prefills the response)
          # This helps ensure NPC responses start with the character name
          partial_assistant = options[:partial_assistant] || options['partial_assistant']
          if partial_assistant
            messages_array << { role: 'assistant', content: partial_assistant }
          end

          body = {
            model: resolve_model(model),
            messages: messages_array,
            max_tokens: opts[:max_tokens]
          }

          body[:system] = system_prompt if system_prompt
          body[:temperature] = opts[:temperature] if opts[:temperature]
          body[:top_p] = opts[:top_p] if opts[:top_p]
          body[:stop_sequences] = opts[:stop] if opts[:stop]

          # Native structured output via Anthropic output_config
          if json_schema
            body[:output_config] = {
              format: {
                type: 'json_schema',
                schema: json_schema
              }
            }
          end

          # Add tools for function calling
          normalized_tools = normalize_tools(tools)
          if normalized_tools
            body[:tools] = normalized_tools.map do |tool|
              { name: tool[:name], description: tool[:description] || '', input_schema: tool[:parameters] }
            end
            body[:tool_choice] = { type: 'tool', name: normalized_tools.first[:name] }
          end

          response = conn.post('v1/messages', body)

          if response.success?
            content = response.body['content'] || []

            # Check for tool_use blocks
            tool_use_blocks = content.select { |c| c['type'] == 'tool_use' }
            if tool_use_blocks.any?
              tool_calls = tool_use_blocks.map do |block|
                { id: block['id'], name: block['name'], arguments: block['input'] || {} }
              end
              return tool_call_response(nil, tool_calls, response.body)
            end

            text = content.find { |c| c['type'] == 'text' }&.dig('text')
            # Prepend partial_assistant if it was used (Claude continues from the partial)
            text = "#{partial_assistant}#{text}" if partial_assistant && text
            success_response(text, response.body)
          else
            error_response(provider_error_message(response))
          end
        rescue Faraday::Error => e
          error_response(faraday_error_message(e))
        end

        # Anthropic doesn't support image generation
        def generate_image(prompt:, api_key:, options: {})
          error_response('Anthropic does not support image generation')
        end
      end
    end
  end
end
