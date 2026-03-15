# frozen_string_literal: true

require_relative 'base_adapter'

module LLM
  module Adapters
    # OpenRouterAdapter handles API requests to OpenRouter.
    #
    # OpenRouter provides access to many models via a unified OpenAI-compatible API.
    # Models are specified as "provider/model-name" (e.g., "anthropic/claude-haiku-4-5").
    #
    class OpenRouterAdapter < BaseAdapter
      BASE_URL = 'https://openrouter.ai/api/v1'

      class << self
        # Generate text completion via OpenRouter
        # @param messages [Array<Hash>] conversation messages
        # @param model [String] model identifier (e.g., "anthropic/claude-haiku-4-5")
        # @param api_key [String] API key
        # @param options [Hash] generation options
        # @param json_mode [Boolean] force JSON output (model-dependent)
        # @return [Hash]
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          timeout = options[:timeout] || BaseAdapter::DEFAULT_TIMEOUT
          conn = build_connection(BASE_URL, api_key, timeout: timeout) do |c|
            c.headers['Authorization'] = "Bearer #{api_key}"
            c.headers['HTTP-Referer'] = options[:referer] || 'https://firefly-mud.com'
            c.headers['X-Title'] = options[:title] || GameSetting.get('game_name') || 'Firefly'
          end

          opts = normalize_options(options)

          body = {
            model: model,
            messages: messages.map { |m| { role: m[:role], content: m[:content] } },
            max_tokens: opts[:max_tokens],
            temperature: opts[:temperature]
          }

          body[:top_p] = opts[:top_p] if opts[:top_p]
          body[:stop] = opts[:stop] if opts[:stop]

          # JSON mode - OpenRouter passes through to the underlying model
          # This works for OpenAI models, Claude uses prompt-based approach
          if json_mode && openai_model?(model)
            body[:response_format] = { type: 'json_object' }
          elsif json_mode
            # Add JSON instruction to system message for non-OpenAI models
            body[:messages] = add_json_instruction(body[:messages])
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

        # Generate image via OpenRouter
        # Most image models on OpenRouter use chat/completions endpoint
        # and return base64 images in the message.images array
        # @param prompt [String] image description
        # @param api_key [String] API key
        # @param options [Hash] image options
        # @return [Hash]
        def generate_image(prompt:, api_key:, options: {})
          conn = build_connection(BASE_URL, api_key) do |c|
            c.headers['Authorization'] = "Bearer #{api_key}"
            c.headers['HTTP-Referer'] = options[:referer] || 'https://firefly-mud.com'
            c.headers['X-Title'] = options[:title] || GameSetting.get('game_name') || 'Firefly'
            c.options.timeout = GameConfig::LLM::TIMEOUTS[:image_generation]
          end

          model = options[:model] || 'bytedance-seed/seedream-4.5'

          # OpenRouter image models use chat/completions with prompt in message
          body = {
            model: model,
            messages: [{ role: 'user', content: "Generate an image of: #{prompt}" }]
          }

          response = conn.post('chat/completions', body)

          # Parse body if it's still a string
          body_data = response.body.is_a?(String) ? JSON.parse(response.body) : response.body

          if response.success?
            parse_image_chat_response(body_data)
          else
            error_msg = body_data.is_a?(Hash) ? body_data.dig('error', 'message') : nil
            image_error_response(error_msg || "HTTP #{response.status}")
          end
        rescue JSON::ParserError
          image_error_response("Invalid JSON response: #{response.body.to_s[0..100]}")
        rescue Faraday::Error => e
          image_error_response(faraday_error_message(e))
        end

        # Parse chat completion response for image data
        # Image models return images in message.images array
        def parse_image_chat_response(body)
          message = body.dig('choices', 0, 'message')
          return image_error_response('No message in response') unless message

          images = message['images']
          if images&.any?
            # Extract base64 data from data URL
            image_url = images.dig(0, 'image_url', 'url')
            if image_url&.start_with?('data:image/')
              # Parse data URL: data:image/jpeg;base64,/9j/...
              match = image_url.match(%r{^data:(image/\w+);base64,(.+)$})
              if match
                mime_type = match[1]
                base64_data = match[2]
                return {
                  success: true,
                  url: nil,
                  base64_data: base64_data,
                  mime_type: mime_type,
                  data: body,
                  error: nil
                }
              end
            elsif image_url
              # Regular URL
              return {
                success: true,
                url: image_url,
                base64_data: nil,
                mime_type: nil,
                data: body,
                error: nil
              }
            end
          end

          # Check for text response (might be rejection)
          content = message['content']
          if content && content.length.positive?
            image_error_response(content)
          else
            image_error_response('No image generated')
          end
        end

        def image_error_response(message)
          { success: false, url: nil, base64_data: nil, mime_type: nil, data: {}, error: message }
        end

        private

        # Check if the model is OpenAI-based (supports native JSON mode)
        def openai_model?(model)
          model.start_with?('openai/')
        end

        # Add JSON instruction to system message
        def add_json_instruction(messages)
          json_instruction = "IMPORTANT: You MUST respond with valid JSON only. No markdown, no explanation, just JSON."

          messages.map.with_index do |msg, i|
            if msg[:role] == 'system'
              msg.merge(content: "#{msg[:content]}\n\n#{json_instruction}")
            elsif i.zero? && messages.none? { |m| m[:role] == 'system' }
              # If no system message, add instruction to first message
              { role: 'system', content: json_instruction }
            else
              msg
            end
          end
        end
      end
    end
  end
end
