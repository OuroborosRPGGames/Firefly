# frozen_string_literal: true

require_relative 'base_adapter'

module LLM
  module Adapters
    # GeminiAdapter handles API requests to Google Gemini.
    #
    # Gemini uses a different format:
    # - API key passed as query parameter
    # - Messages use 'parts' array with 'text' field
    # - Roles are 'user' and 'model' (not 'assistant')
    # - System prompt is included as part of first user message
    #
    class GeminiAdapter < BaseAdapter
      BASE_URL = 'https://generativelanguage.googleapis.com/v1beta'

      class << self
        # Generate text completion via Gemini API
        # @param messages [Array<Hash>] conversation messages
        # @param model [String] model identifier (gemini-3-flash-preview, gemini-3.1-flash-lite-preview, etc.)
        # @param api_key [String] API key
        # @param options [Hash] generation options
        # @param json_mode [Boolean] force JSON output (prompt-based)
        # @param response_schema [Hash, nil] Gemini structured output JSON schema (uses responseMimeType)
        # @return [Hash]
        def generate(messages:, model:, api_key:, options: {}, json_mode: false, tools: nil, response_schema: nil)
          endpoint = "#{BASE_URL}/models/#{model}:generateContent?key=#{api_key}"

          timeout = options[:timeout] || options['timeout'] || GameConfig::LLM::TIMEOUTS[:gemini]

          conn = Faraday.new do |c|
            c.request :json
            c.response :json, content_type: /\bjson$/
            c.adapter Faraday.default_adapter
            c.options.timeout = timeout
          end

          opts = normalize_options(options)

          # Convert messages to Gemini format
          gemini_contents = convert_messages_to_gemini(messages, json_mode && !response_schema)

          body = {
            contents: gemini_contents,
            generationConfig: {
              maxOutputTokens: opts[:max_tokens],
              temperature: opts[:temperature],
              topP: opts[:top_p]
            }.compact
          }

          # Thinking config for Gemini 3+ models
          thinking_level = options[:thinking_level] || options['thinking_level']
          thinking_budget = options[:thinking_budget] || options['thinking_budget']
          if thinking_level
            body[:generationConfig][:thinkingConfig] = { thinkingLevel: thinking_level.to_s }
          elsif !thinking_budget.nil?
            body[:generationConfig][:thinkingConfig] = { thinkingBudget: thinking_budget.to_i }
          end

          # Structured output via Gemini's native responseSchema
          if response_schema
            body[:generationConfig][:responseMimeType] = 'application/json'
            body[:generationConfig][:responseSchema] = response_schema
          end

          # Add stop sequences if provided
          body[:generationConfig][:stopSequences] = opts[:stop] if opts[:stop]

          # Add tools for function calling
          normalized_tools = normalize_tools(tools)
          if normalized_tools
            body[:tools] = [{
              functionDeclarations: normalized_tools.map do |tool|
                {
                  name: tool[:name],
                  description: tool[:description] || '',
                  parameters: tool[:parameters]
                }
              end
            }]
            body[:tool_config] = { function_calling_config: { mode: 'ANY' } }
          end

          response = conn.post(endpoint, body)

          if response.success?
            parts = response.body.dig('candidates', 0, 'content', 'parts') || []

            # Check for function call responses
            function_calls = parts.select { |p| p['functionCall'] }
            if function_calls.any?
              tool_calls = function_calls.map do |fc|
                call = fc['functionCall']
                args = call['args']
                args = JSON.parse(args) if args.is_a?(String)
                { id: SecureRandom.hex(12), name: call['name'], arguments: args || {} }
              end
              return tool_call_response(nil, tool_calls, response.body)
            end

            text = parts.map { |p| p['text'] }.compact.first
            success_response(text, response.body)
          else
            error_response(provider_error_message(response))
          end
        rescue Faraday::Error => e
          error_response(faraday_error_message(e))
        end

        # Generate image using Gemini's image generation model
        # @param prompt [String] image description
        # @param api_key [String] API key
        # @param options [Hash] image options
        #   - :model [String] model name (default: gemini-3.1-flash-image-preview)
        #   - :aspect_ratio [String] e.g., "1:1", "16:9", "9:16"
        # @return [Hash] { success: Boolean, url: String, data: Hash, error: String }
        def generate_image(prompt:, api_key:, options: {})
          model = options[:model] || 'gemini-3.1-flash-image-preview'
          endpoint = "#{BASE_URL}/models/#{model}:generateContent?key=#{api_key}"

          conn = Faraday.new do |c|
            c.request :json
            c.response :json, content_type: /\bjson$/
            c.adapter Faraday.default_adapter
            c.options.timeout = GameConfig::LLM::TIMEOUTS[:image_generation]
          end

          generation_config = {
            responseModalities: ['TEXT', 'IMAGE']
          }

          # Add aspect ratio if specified
          if options[:aspect_ratio]
            generation_config[:imageConfig] = { aspectRatio: options[:aspect_ratio] }
          end

          # Thinking config for image generation
          thinking_level = options[:thinking_level] || options['thinking_level']
          thinking_budget = options[:thinking_budget] || options['thinking_budget']
          if thinking_level
            generation_config[:thinkingConfig] = { thinkingLevel: thinking_level.to_s }
          elsif !thinking_budget.nil?
            generation_config[:thinkingConfig] = { thinkingBudget: thinking_budget.to_i }
          end

          # Build content parts
          parts = []

          # Add reference image if provided (for blueprint mode)
          ref = options[:reference_image]
          if ref.is_a?(Hash) && ref[:data]
            parts << { inlineData: { mimeType: ref[:mime_type] || 'image/png', data: ref[:data] } }
          end

          # Add text prompt
          parts << { text: prompt }

          body = {
            contents: [{ parts: parts }],
            generationConfig: generation_config
          }

          response = conn.post(endpoint, body)

          if response.success?
            parse_image_response(response.body)
          else
            image_error_response(provider_error_message(response))
          end
        rescue Faraday::Error => e
          image_error_response(faraday_error_message(e))
        end

        # Parse image generation response
        def parse_image_response(body)
          parts = body.dig('candidates', 0, 'content', 'parts') || []

          # Find the image part - look for inlineData with image mime type
          image_part = parts.find do |p|
            p.dig('inlineData', 'mimeType')&.start_with?('image/') ||
              p.dig('inline_data', 'mimeType')&.start_with?('image/') ||
              p.dig('inline_data', 'mime_type')&.start_with?('image/')
          end

          if image_part
            # Handle different response formats (camelCase vs snake_case)
            inline_data = image_part['inlineData'] || image_part['inline_data']
            mime_type = inline_data['mimeType'] || inline_data['mime_type']
            base64_data = inline_data['data']

            {
              success: true,
              url: nil, # Gemini returns base64 data, not URL
              base64_data: base64_data,
              mime_type: mime_type,
              data: body,
              error: nil
            }
          else
            # Check if there's a text response (might be a refusal or error)
            text_part = parts.find { |p| p['text'] }
            error_msg = text_part ? text_part['text'] : 'No image generated'
            image_error_response(error_msg)
          end
        end

        def image_error_response(message)
          { success: false, url: nil, base64_data: nil, mime_type: nil, data: {}, error: message }
        end

        private

        # Convert standard messages to Gemini format
        # Supports both text-only and multimodal (text + image) messages
        # @param messages [Array<Hash>] standard messages
        # @param json_mode [Boolean] whether to add JSON instruction
        # @return [Array<Hash>]
        def convert_messages_to_gemini(messages, json_mode)
          system_prompt = extract_system_message(messages)
          filtered = filter_system_messages(messages)

          # Add JSON instruction to system prompt
          if json_mode
            json_instruction = "\n\nIMPORTANT: Respond with valid JSON only. No markdown, no explanation."
            system_prompt = system_prompt ? "#{system_prompt}#{json_instruction}" : json_instruction.strip
          end

          result = []
          filtered.each_with_index do |msg, index|
            # Map 'assistant' to 'model' for Gemini
            # Support both symbol and string keys (string keys after JSONB round-trip)
            msg_role = msg[:role] || msg['role']
            role = msg_role == 'assistant' ? 'model' : 'user'
            content = msg[:content] || msg['content']

            # Build parts array based on content type
            parts = build_message_parts(content, index, role, system_prompt)

            result << { role: role, parts: parts }
          end

          result
        end

        # Build parts array from message content
        # Handles both string content and multimodal array content
        # @param content [String, Array] message content
        # @param index [Integer] message index (for system prompt prepending)
        # @param role [String] message role
        # @param system_prompt [String, nil] system prompt to prepend to first user message
        # @return [Array<Hash>] parts array for Gemini API
        def build_message_parts(content, index, role, system_prompt)
          parts = []

          if content.is_a?(Array)
            # Multimodal content - array of { type: 'text'|'image_url', ... }
            # Support both symbol and string keys (string keys after JSONB round-trip)
            content.each do |item|
              item_type = item[:type] || item['type']
              case item_type
              when 'text'
                text = item[:text] || item['text']
                # Prepend system prompt to first text in first user message
                text = "#{system_prompt}\n\n#{text}" if index.zero? && role == 'user' && system_prompt && parts.empty?
                parts << { text: text }
              when 'image_url', 'image'
                # Handle base64 encoded image data
                # Note: Gemini API expects camelCase keys
                parts << {
                  inlineData: {
                    mimeType: item[:mime_type] || item['mime_type'] || 'image/png',
                    data: item[:data] || item['data']
                  }
                }
              end
            end
          else
            # Simple string content
            text = content
            text = "#{system_prompt}\n\n#{text}" if index.zero? && role == 'user' && system_prompt
            parts << { text: text }
          end

          parts
        end
      end
    end
  end
end
