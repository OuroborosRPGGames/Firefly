# frozen_string_literal: true

require_relative 'base_adapter'

module LLM
  module Adapters
    # OpenAIAdapter handles API requests to OpenAI.
    #
    # Supports both chat completions and image generation (DALL-E).
    #
    class OpenAIAdapter < BaseAdapter
      BASE_URL = 'https://api.openai.com/v1'

      class << self
        # Generate text completion via OpenAI Chat Completions API
        # @param messages [Array<Hash>] conversation messages
        # @param model [String] model identifier (gpt-5.4, gpt-5-mini, etc.)
        # @param api_key [String] API key
        # @param options [Hash] generation options
        # @param json_mode [Boolean] force JSON output
        # @return [Hash]
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          timeout = options[:timeout] || BaseAdapter::DEFAULT_TIMEOUT
          conn = build_connection(BASE_URL, api_key, timeout: timeout) do |c|
            c.headers['Authorization'] = "Bearer #{api_key}"
          end

          opts = normalize_options(options)
          body = {
            model: model,
            messages: messages.map { |m| { role: m[:role], content: m[:content] } },
            temperature: opts[:temperature]
          }

          # Reasoning models (gpt-5, gpt-5.4, o1*, o3*) use max_completion_tokens instead of max_tokens.
          if model.match?(/\A(gpt-5|o[13])(\z|[-.])/)
            body[:max_completion_tokens] = opts[:max_tokens]
          else
            body[:max_tokens] = opts[:max_tokens]
          end

          body[:top_p] = opts[:top_p] if opts[:top_p]
          body[:stop] = opts[:stop] if opts[:stop]

          # Reasoning effort (for models that support it like GPT-5.x)
          reasoning_effort = options[:reasoning_effort] || options['reasoning_effort']
          if reasoning_effort
            body[:reasoning] = { effort: reasoning_effort.to_s }
          end

          # JSON mode
          if json_mode
            body[:response_format] = { type: 'json_object' }
          end

          # Add tools for function calling (supersedes json_mode)
          normalized_tools = normalize_tools(tools)
          if normalized_tools
            body[:tools] = normalized_tools.map do |tool|
              { type: 'function', function: { name: tool[:name], description: tool[:description] || '', parameters: tool[:parameters] } }
            end
            body[:tool_choice] = { type: 'function', function: { name: normalized_tools.first[:name] } }
            body.delete(:response_format) # tools supersede json_mode
          end

          response = conn.post('chat/completions', body)

          if response.success?
            message = response.body.dig('choices', 0, 'message') || {}

            # Check for tool calls
            if message['tool_calls']&.any?
              tool_calls = message['tool_calls'].map do |tc|
                func = tc['function'] || {}
                args = func['arguments']
                args = JSON.parse(args) if args.is_a?(String)
                { id: tc['id'], name: func['name'], arguments: args || {} }
              end
              return tool_call_response(nil, tool_calls, response.body)
            end

            text = message['content']
            success_response(text, response.body)
          else
            error_response(provider_error_message(response))
          end
        rescue Faraday::Error => e
          error_response(faraday_error_message(e))
        end

        # Generate image via DALL-E or gpt-image-1
        # @param prompt [String] image description
        # @param api_key [String] API key
        # @param options [Hash] image options (size, quality, style, n, model, output_format)
        # @return [Hash]
        def generate_image(prompt:, api_key:, options: {})
          conn = build_connection(BASE_URL, api_key) do |c|
            c.headers['Authorization'] = "Bearer #{api_key}"
          end

          model = options[:model] || 'dall-e-3'
          gpt_image = model.start_with?('gpt-image')

          body = {
            model: model,
            prompt: prompt,
            n: options[:n] || 1
          }

          if gpt_image
            # gpt-image-1 parameters (no response_format — returns b64 via output_format)
            body[:size] = options[:size] || '1024x1024'
            body[:quality] = options[:quality] || 'medium' # low, medium, high
            body[:output_format] = options[:output_format] || 'png'
          else
            # DALL-E 3 parameters
            body[:size] = options[:size] || '1024x1024'
            body[:quality] = options[:quality] if options[:quality] # 'standard' or 'hd'
            body[:style] = options[:style] if options[:style]       # 'vivid' or 'natural'
            body[:response_format] = options[:response_format] || 'url'
          end

          response = conn.post('images/generations', body)

          if response.success?
            data_item = response.body.dig('data', 0) || {}

            if data_item['b64_json']
              # Base64 response (gpt-image-1)
              mime = options[:output_format] == 'webp' ? 'image/webp' : 'image/png'
              success_response(nil, response.body).merge(
                base64_data: data_item['b64_json'],
                mime_type: mime,
                url: nil
              )
            else
              # URL response (DALL-E)
              url = data_item['url']
              success_response(nil, response.body).merge(url: url)
            end
          else
            error_response(provider_error_message(response))
          end
        rescue Faraday::Error => e
          error_response(faraday_error_message(e))
        end
      end
    end
  end
end
