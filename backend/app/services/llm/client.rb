# frozen_string_literal: true

module LLM
  # Client is the unified entry point for all LLM operations.
  #
  # Provides synchronous and asynchronous text/image generation across
  # multiple providers (Anthropic, OpenAI, Gemini, OpenRouter).
  #
  # Usage:
  #   # Synchronous (blocking) - for immediate needs
  #   result = LLM::Client.generate(
  #     prompt: "Describe this room",
  #     model: "claude-haiku-4-5",
  #     options: { max_tokens: 500, temperature: 0.7 }
  #   )
  #
  #   # Asynchronous (default) - game continues while processing
  #   LLM::Client.generate_async(
  #     prompt: "Describe this room",
  #     callback: "RoomDescriptionHandler",
  #     context: { room_id: 123, character_instance_id: 456 }
  #   )
  #
  #   # JSON mode - force structured response
  #   result = LLM::Client.generate(
  #     prompt: "List 5 NPC names with ages as JSON",
  #     json_mode: true
  #   )
  #
  #   # Multi-turn conversation
  #   conversation = LLM::Client.start_conversation(
  #     purpose: "npc_chat",
  #     system_prompt: "You are an innkeeper named Greta..."
  #   )
  #
  #   LLM::Client.chat_async(
  #     conversation: conversation,
  #     message: "What rooms do you have?",
  #     callback: "NPCResponseHandler"
  #   )
  #
  #   # Image generation
  #   LLM::Client.generate_image_async(
  #     prompt: "A dark tavern with flickering candles",
  #     callback: "RoomBackgroundHandler"
  #   )
  #
  class Client
    class << self
      # Synchronous text generation. Normalizes any raised exception to
      # { success: false, error: message } so callers have a uniform contract.
      # @return [Hash] { success: Boolean, text: String, data: Hash, error: String, tool_calls: Array }
      def generate(prompt:, model: nil, provider: nil, options: {}, json_mode: false, tools: nil, conversation: nil)
        TextGenerationService.generate(
          prompt: prompt,
          model: model,
          provider: provider,
          options: options,
          json_mode: json_mode,
          tools: tools,
          conversation: conversation
        )
      rescue StandardError => e
        warn "[LLM::Client] generate failed: #{e.message}"
        { success: false, error: e.message, text: nil }
      end

      # Asynchronous text generation - returns immediately, invokes callback on completion
      # @param prompt [String] the prompt to send
      # @param callback [String] handler class name to invoke on completion
      # @param context [Hash] context data passed to callback
      # @param model [String, nil] specific model to use
      # @param provider [String, nil] specific provider to use
      # @param options [Hash] LLM options
      # @param json_mode [Boolean] force JSON response format
      # @param conversation [LLMConversation, nil] existing conversation
      # @param character_instance [CharacterInstance, nil] associated character
      # @return [LLMRequest] the created request record
      def generate_async(prompt:, callback: nil, context: {}, model: nil, provider: nil,
                         options: {}, json_mode: false, conversation: nil, character_instance: nil)
        options = options.merge(json_mode: true) if json_mode

        request = LLMRequest.create_text_request(
          prompt: prompt,
          callback: callback,
          context: context,
          provider: provider,
          model: model,
          options: options,
          conversation: conversation,
          character_instance: character_instance
        )

        # Spawn thread immediately for fastest response
        RequestProcessor.enqueue_async(request)

        request
      end

      # Submit a batch of requests for parallel processing.
      #
      # Each request hash can include:
      #   :prompt      [String]       — simple text prompt (wrapped as user message)
      #   :messages    [Array<Hash>]  — full message array (multipart: images, text, etc.)
      #   :tools       [Array<Hash>]  — tool/function definitions for the adapter
      #   :response_schema [Hash]     — Gemini structured output schema
      #   :provider    [String]       — provider name
      #   :model       [String]       — model name
      #   :options     [Hash]         — adapter options (max_tokens, temperature, timeout, etc.)
      #   :callback    [String]       — per-request callback class name
      #   :context     [Hash]         — per-request context data
      #   :json_mode   [Boolean]      — force JSON response
      #
      # @param requests [Array<Hash>]
      # @param callback_handler [String, nil] batch-level callback class name
      # @param callback_context [Hash] context for batch callback
      # @return [LlmBatch]
      def batch_submit(requests, callback_handler: nil, callback_context: {})
        batch = LlmBatch.create(
          total_count: requests.size,
          status: 'pending',
          callback_handler: callback_handler,
          callback_context: callback_context
        )

        REDIS_POOL.with do |redis|
          redis.set("#{LlmBatch::REDIS_KEY_PREFIX}:#{batch.id}:completed", 0)
        end

        requests.each do |req|
          options = req[:options] || {}
          options = options.merge(json_mode: true) if req[:json_mode]

          # Store full messages, tools, and response_schema in options for RequestProcessor
          options = options.merge(messages: req[:messages]) if req[:messages]
          options = options.merge(tools: req[:tools]) if req[:tools]
          options = options.merge(response_schema: req[:response_schema]) if req[:response_schema]

          provider = req[:provider] || AIProviderService.primary_provider
          model = req[:model] || AIProviderService::DEFAULT_MODELS[provider]

          request = LLMRequest.create_text_request(
            prompt: req[:prompt] || '',
            callback: req[:callback],
            context: req[:context] || {},
            provider: provider,
            model: model,
            options: options
          )
          request.update(llm_batch_id: batch.id)

          RequestProcessor.enqueue_async(request)
        end

        batch
      end

      # Start a new conversation for multi-turn chat; returns [LLMConversation]
      def start_conversation(purpose:, system_prompt: nil, character_instance: nil, metadata: {})
        LLMConversation.start(
          purpose: purpose,
          system_prompt: system_prompt,
          character_instance: character_instance,
          metadata: metadata
        )
      end

      # Continue a conversation asynchronously
      # @param conversation [LLMConversation] the conversation to continue
      # @param message [String] user message to add
      # @param callback [String] handler class name
      # @param context [Hash] context data
      # @param options [Hash] LLM options
      # @return [LLMRequest]
      def chat_async(conversation:, message:, callback: nil, context: {}, options: {})
        # Add the user message to conversation
        conversation.add_message(role: 'user', content: message)

        # Build prompt with full conversation history
        messages = conversation.message_history(include_system: true)
        prompt = format_conversation_prompt(messages)

        generate_async(
          prompt: prompt,
          callback: callback,
          context: context.merge(conversation_id: conversation.id),
          options: options,
          conversation: conversation
        )
      end

      # Synchronous chat - for when you need immediate response
      # @param conversation [LLMConversation] the conversation to continue
      # @param message [String] user message to add
      # @param options [Hash] LLM options
      # @return [Hash] { success: Boolean, text: String, data: Hash }
      def chat(conversation:, message:, options: {})
        conversation.add_message(role: 'user', content: message)

        messages = conversation.message_history(include_system: true)
        prompt = format_conversation_prompt(messages)

        result = generate(prompt: prompt, options: options, conversation: conversation)

        if result[:success] && result[:text]
          conversation.add_message(role: 'assistant', content: result[:text])
        end

        result
      end

      # Asynchronous image generation
      # @param prompt [String] the image description
      # @param callback [String] handler class name
      # @param context [Hash] context data
      # @param options [Hash] image options (size, style, quality)
      # @param character_instance [CharacterInstance, nil] associated character
      # @return [LLMRequest]
      def generate_image_async(prompt:, callback: nil, context: {}, options: {}, character_instance: nil)
        request = LLMRequest.create_image_request(
          prompt: prompt,
          callback: callback,
          context: context,
          options: options,
          character_instance: character_instance
        )

        # Spawn thread immediately
        RequestProcessor.enqueue_async(request)

        request
      end

      # Synchronous image generation; returns { success:, url:, data:, error: }
      def generate_image(prompt:, options: {})
        ImageGenerationService.generate(prompt: prompt, options: options)
      end

      # ========== EMBEDDING METHODS ==========

      # Generate embedding for text
      #
      # @param text [String] text to embed
      # @param model [String, nil] specific embedding model
      # @param input_type [String] 'document' or 'query'
      #   - Use 'document' when embedding content for storage
      #   - Use 'query' when embedding a search query
      # @return [Hash] { success: Boolean, embedding: Array, dimensions: Integer }
      def embed(text:, model: nil, input_type: 'document')
        EmbeddingService.generate(text: text, model: model, input_type: input_type)
      end

      # Generate embeddings for multiple texts in one API call
      #
      # @param texts [Array<String>] texts to embed
      # @param model [String, nil] specific embedding model
      # @param input_type [String] 'document' or 'query'
      # @return [Hash] { success: Boolean, embeddings: Array, dimensions: Integer }
      def embed_batch(texts:, model: nil, input_type: 'document')
        EmbeddingService.generate_batch(texts: texts, model: model, input_type: input_type)
      end

      # Asynchronous embedding generation
      #
      # @param text [String] text to embed
      # @param callback [String, nil] handler class name to invoke on completion
      # @param context [Hash] context data passed to callback
      # @param model [String, nil] specific embedding model
      # @param input_type [String] 'document' or 'query'
      # @param character_instance [CharacterInstance, nil] associated character
      # @return [LLMRequest]
      def embed_async(text:, callback: nil, context: {}, model: nil, input_type: 'document',
                      character_instance: nil)
        request = LLMRequest.create_embedding_request(
          text: text,
          callback: callback,
          context: context,
          model: model || EmbeddingService.default_model,
          input_type: input_type,
          character_instance: character_instance
        )

        RequestProcessor.enqueue_async(request)
        request
      end

      # Check if embedding service is available
      # @return [Boolean]
      def embeddings_available?
        EmbeddingService.available?
      end

      # Check if LLM services are available
      # @return [Boolean]
      def available?
        AIProviderService.any_available?
      end

      # Get status of LLM services
      # @return [Hash]
      def status
        {
          available: available?,
          providers: AIProviderService.status_summary,
          pending_requests: LLMRequest.where(status: %w[pending processing]).count,
          recent_failures: LLMRequest.where(status: 'failed')
                                     .where { created_at > Time.now - GameConfig::Timeouts::RATE_LIMIT_WINDOW_SECONDS }
                                     .count
        }
      end

      private

      # Format conversation history into a single prompt for providers that don't support messages array
      # @param messages [Array<Hash>] conversation messages
      # @return [String]
      def format_conversation_prompt(messages)
        messages.map do |msg|
          role = msg[:role].capitalize
          content = msg[:content]
          "#{role}: #{content}"
        end.join("\n\n")
      end
    end
  end
end
