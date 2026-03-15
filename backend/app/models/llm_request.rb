# frozen_string_literal: true

# LLMRequest tracks async LLM API requests
#
# Requests are created with status 'pending', processed in a background thread,
# and updated to 'completed' or 'failed'. A callback handler is invoked on completion.
#
# Usage:
#   request = LLMRequest.create_text_request(
#     prompt: 'Describe this room',
#     callback: 'RoomDescriptionHandler',
#     context: { room_id: 123 }
#   )
#
#   # Later, when processed:
#   request.status          # => 'completed'
#   request.response_text   # => 'The room is dark and dusty...'
#
class LLMRequest < Sequel::Model
  include StatusEnum

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  STALE_PROCESSING_SECONDS = 300

  many_to_one :llm_conversation, class: 'LLMConversation'
  many_to_one :character_instance
  many_to_one :llm_batch

  status_enum :status, %w[pending processing completed failed cancelled]
  REQUEST_TYPES = %w[text image embedding].freeze

  # Access the 'model' column via llm_model to avoid conflict with Sequel's #model method
  # Sequel uses #model internally to return the class, so we can't override it
  def llm_model
    self[:model]
  end

  def llm_model=(value)
    self[:model] = value
  end

  def validate
    super
    validates_presence [:request_id, :request_type, :status]
    validates_unique :request_id
    validate_status_enum
    validates_includes REQUEST_TYPES, :request_type
  end

  # Create a text generation request
  # @param prompt [String] the prompt to send
  # @param callback [String, nil] handler class name
  # @param context [Hash] context data passed to callback
  # @param provider [String, nil] specific provider to use
  # @param model [String, nil] specific model to use
  # @param options [Hash] LLM options (max_tokens, temperature, etc.)
  # @param conversation [LLMConversation, nil] conversation for multi-turn
  # @param character_instance [CharacterInstance, nil] associated character
  # @return [LLMRequest]
  def self.create_text_request(prompt:, callback: nil, context: {}, provider: nil, model: nil,
                               options: {}, conversation: nil, character_instance: nil)
    provider ||= AIProviderService.primary_provider
    model ||= AIProviderService::DEFAULT_MODELS[provider] if provider

    create(
      request_id: SecureRandom.uuid,
      request_type: 'text',
      status: 'pending',
      prompt: prompt,
      callback_handler: callback,
      context: context,
      provider: provider,
      model: model,
      options: options,
      llm_conversation_id: conversation&.id,
      character_instance_id: character_instance&.id
    )
  end

  # Create an image generation request
  # @param prompt [String] the image description
  # @param callback [String, nil] handler class name
  # @param context [Hash] context data passed to callback
  # @param options [Hash] image options (size, style, etc.)
  # @param character_instance [CharacterInstance, nil] associated character
  # @return [LLMRequest]
  def self.create_image_request(prompt:, callback: nil, context: {}, options: {}, character_instance: nil)
    create(
      request_id: SecureRandom.uuid,
      request_type: 'image',
      status: 'pending',
      prompt: prompt,
      callback_handler: callback,
      context: context,
      provider: 'openai',
      model: 'dall-e-3',
      options: options,
      character_instance_id: character_instance&.id
    )
  end

  # Create an embedding generation request
  # @param text [String] text to embed
  # @param callback [String, nil] handler class name
  # @param context [Hash] context data passed to callback
  # @param model [String] embedding model (voyage-3-large, etc.)
  # @param input_type [String] 'document' or 'query'
  # @param character_instance [CharacterInstance, nil] associated character
  # @return [LLMRequest]
  def self.create_embedding_request(text:, callback: nil, context: {}, model: 'voyage-3-large',
                                    input_type: 'document', character_instance: nil)
    create(
      request_id: SecureRandom.uuid,
      request_type: 'embedding',
      status: 'pending',
      prompt: text,
      callback_handler: callback,
      context: context,
      provider: 'voyage',
      model: model,
      options: { input_type: input_type },
      character_instance_id: character_instance&.id
    )
  end

  # Find pending requests ready for processing
  # @return [Sequel::Dataset]
  def self.pending
    where(status: 'pending').order(:created_at)
  end

  # Mark as processing
  def start_processing!
    update(status: 'processing', started_at: Time.now)
  end

  # Atomically claim this request for processing.
  #
  # Prevents duplicate processing when the same request is queued multiple times.
  # Allows reclaiming stale "processing" rows (e.g. worker crash).
  #
  # @param stale_after [Integer] how old a processing row must be to reclaim
  # @return [Boolean] true if this caller claimed the request
  def claim_for_processing!(stale_after: STALE_PROCESSING_SECONDS)
    now = Time.now
    stale_cutoff = now - stale_after

    pending_filter = Sequel.expr(status: 'pending')
    stale_processing_filter = Sequel.expr(status: 'processing') &
      (Sequel.expr(started_at: nil) | (Sequel[:started_at] < stale_cutoff))

    self.class.where(id: id)
      .where(pending_filter | stale_processing_filter)
      .update(status: 'processing', started_at: now) == 1
  end

  # Mark as completed with result
  # @param text [String, nil] response text
  # @param url [String, nil] response URL (for images)
  # @param data [Hash] full response data
  def complete!(text: nil, url: nil, data: {})
    now = Time.now
    duration = started_at ? ((now - started_at) * 1000).to_i : nil

    update(
      status: 'completed',
      response_text: text,
      response_url: url,
      response_data: data,
      completed_at: now,
      duration_ms: duration
    )
  end

  # Mark as failed
  # @param error [String] error message
  def fail!(error)
    update(
      status: 'failed',
      error_message: error.to_s[0..999],
      completed_at: Time.now
    )
  end

  # Increment retry count and check if should retry
  # @return [Boolean] true if should retry
  def should_retry?
    return false if retry_count >= max_retries

    update(retry_count: retry_count + 1, status: 'pending')
    true
  end

  # Parse options JSONB
  # @return [Hash]
  def parsed_options
    parse_jsonb(options)
  end

  # Parse context JSONB
  # @return [Hash]
  def parsed_context
    parse_jsonb(context)
  end

  # Parse response_data JSONB
  # @return [Hash]
  def parsed_response_data
    parse_jsonb(response_data)
  end

  # Check if this is a text request
  def text?
    request_type == 'text'
  end

  # Check if this is an image request
  def image?
    request_type == 'image'
  end

  # Check if this is an embedding request
  def embedding?
    request_type == 'embedding'
  end

  private

  def parse_jsonb(value)
    return {} if value.nil?
    # Handle both regular Hash and Sequel JSONB types
    return value.to_h if value.respond_to?(:to_h) && !value.is_a?(String)

    JSON.parse(value)
  rescue JSON::ParserError
    {}
  end
end
