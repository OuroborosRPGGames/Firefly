# frozen_string_literal: true

module LLM
  # RequestProcessor handles async LLM request processing.
  #
  # Enqueues requests to Sidekiq for processing, processes the request,
  # and invokes the callback handler when complete.
  #
  # Flow:
  #   1. Request enqueued to Sidekiq via LlmRequestJob
  #   2. Worker picks up request, marks 'processing'
  #   3. HTTP call to provider
  #   4. Parse response
  #   5. Update LLMRequest record
  #   6. Invoke callback handler
  #   7. If failed, Sidekiq retries with exponential backoff
  #
  class RequestProcessor
    RETRY_DELAYS = GameConfig::Timeouts::LLM_RETRY_DELAYS.freeze

    class << self
      # Enqueue a request for async processing via Sidekiq.
      # @param request [LLMRequest] the request to process
      def enqueue_async(request)
        LlmRequestJob.perform_async(request.id)
      end

      # Process a request (called by Sidekiq worker)
      # @param request [LLMRequest] the request to process
      # @param claimed [Boolean] true when caller already atomically claimed this request
      def process(request, claimed: false)
        request.start_processing! unless claimed

        result = if request.text?
                   process_text_request(request)
                 elsif request.image?
                   process_image_request(request)
                 elsif request.embedding?
                   process_embedding_request(request)
                 else
                   { success: false, error: "Unknown request type: #{request.request_type}" }
                 end

        if result[:success]
          handle_success(request, result)
        else
          handle_failure(request, result[:error])
        end
      end

      private

      def process_text_request(request)
        adapter = TextGenerationService.adapter_for(request.provider)
        return { success: false, error: "Unknown provider: #{request.provider}" } unless adapter

        api_key = AIProviderService.api_key_for(request.provider)
        return { success: false, error: "No API key for #{request.provider}" } unless api_key

        # Normalize parsed_options to symbol keys at the boundary so downstream
        # code never needs dual string/symbol lookups.
        options = normalize_option_keys(request.parsed_options)

        # Use full messages from options if provided (multipart: images + text),
        # otherwise build simple messages from prompt string
        messages = if options[:messages]
                     options.delete(:messages)
                   else
                     build_messages(request)
                   end

        # Extract tools and response_schema from options if provided
        tools         = options.delete(:tools)
        response_schema = options.delete(:response_schema)

        generate_args = {
          messages: messages,
          model: request.llm_model,
          api_key: api_key,
          options: options,
          json_mode: options[:json_mode] || false
        }
        generate_args[:tools] = tools if tools
        generate_args[:response_schema] = response_schema if response_schema

        adapter.generate(**generate_args)
      rescue Faraday::TooManyRequestsError => e
        { success: false, error: "429 Rate limited: #{e.message}" }
      rescue Faraday::Error => e
        { success: false, error: "HTTP error: #{e.message}" }
      end

      def process_image_request(request)
        adapter = TextGenerationService.adapter_for(request.provider)
        return { success: false, error: "Unknown provider: #{request.provider}" } unless adapter

        api_key = AIProviderService.api_key_for(request.provider)
        return { success: false, error: "No API key for #{request.provider}" } unless api_key

        options = request.parsed_options

        result = adapter.generate_image(
          prompt: request.prompt,
          api_key: api_key,
          options: options
        )

        # Download image if successful
        if result[:success] && result[:url]
          local_path = ImageDownloader.download(result[:url], request)
          result[:local_url] = local_path if local_path
        end

        result
      rescue Faraday::TooManyRequestsError => e
        { success: false, error: "429 Rate limited: #{e.message}" }
      rescue Faraday::Error => e
        { success: false, error: "HTTP error: #{e.message}" }
      end

      def process_embedding_request(request)
        options = request.parsed_options
        input_type = options['input_type'] || options[:input_type] || 'document'

        EmbeddingService.generate(
          text: request.prompt,
          model: request.llm_model,
          input_type: input_type
        )
      rescue Faraday::TooManyRequestsError => e
        { success: false, error: "429 Rate limited: #{e.message}" }
      rescue Faraday::Error => e
        { success: false, error: "HTTP error: #{e.message}" }
      end

      def build_messages(request)
        messages = []

        # Add conversation history if present
        if request.llm_conversation
          conv = request.llm_conversation
          if conv.system_prompt && !conv.system_prompt.empty?
            messages << { role: 'system', content: conv.system_prompt }
          end
          conv.llm_messages.each do |msg|
            messages << { role: msg.role, content: msg.content }
          end
        end

        # Add the current prompt
        messages << { role: 'user', content: request.prompt }

        messages
      end

      def handle_success(request, result)
        # Handle embedding results differently (no text/url, embedding in data)
        if request.embedding?
          request.complete!(
            text: nil,
            url: nil,
            data: {
              embedding: result[:embedding],
              embeddings: result[:embeddings],
              dimensions: result[:dimensions],
              model: result[:model],
              usage: result[:usage]
            }
          )
        else
          # Update request record for text/image
          request.complete!(
            text: result[:text],
            url: result[:local_url] || result[:url],
            data: result[:data] || {}
          )

          # Add assistant response to conversation if present
          if request.llm_conversation && result[:text]
            request.llm_conversation.add_message(
              role: 'assistant',
              content: result[:text]
            )
          end
        end

        # Invoke callback handler
        invoke_callback(request, result)
      end

      def handle_failure(request, error_message)
        if request.should_retry?
          # Re-enqueue for retry with delay via Sidekiq
          delay = RETRY_DELAYS[request.retry_count - 1] || RETRY_DELAYS.last
          LlmRequestJob.perform_in(delay, request.id)
        else
          request.fail!(error_message)
          invoke_callback(request, { success: false, error: error_message })
        end
      end

      def invoke_callback(request, result)
        return unless request.callback_handler && !request.callback_handler.empty?

        begin
          handler_class = Object.const_get(request.callback_handler)
          handler_class.call(request, result)
        rescue NameError => e
          log_error("Callback handler not found: #{request.callback_handler} - #{e.message}")
        rescue StandardError => e
          log_error("Callback handler error: #{e.message}")
        end
      end

      def log_error(message)
        warn "[LLM::RequestProcessor] #{message}"
      end

      # Convert all top-level keys to symbols so callers never need dual
      # string/symbol lookups (parsed_options can come from DB JSON or direct call).
      def normalize_option_keys(opts)
        return {} unless opts.is_a?(Hash)

        opts.each_with_object({}) do |(k, v), h|
          h[k.to_sym] = v
        end
      end
    end
  end
end
