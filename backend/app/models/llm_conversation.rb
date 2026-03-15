# frozen_string_literal: true

# LLMConversation tracks multi-turn chat sessions with LLM providers
#
# Each conversation has a system prompt and purpose, and stores message history
# in the related LLMMessage records.
#
# Usage:
#   conversation = LLMConversation.start(
#     purpose: 'npc_chat',
#     system_prompt: 'You are an innkeeper named Greta...',
#     character_instance: player
#   )
#
#   conversation.add_message(role: 'user', content: 'Hello!')
#   conversation.add_message(role: 'assistant', content: 'Welcome to my inn!')
#
class LLMConversation < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  one_to_many :llm_messages, class: 'LLMMessage', order: :created_at
  one_to_many :llm_requests, class: 'LLMRequest'
  many_to_one :character_instance

  PURPOSES = %w[npc_chat room_description item_description quest_generation world_building general activity_persuade activity_free_roll].freeze

  def validate
    super
    validates_presence [:conversation_id]
    validates_unique :conversation_id
    validates_includes PURPOSES, :purpose if purpose
  end

  # Start a new conversation
  # @param purpose [String] conversation purpose (npc_chat, room_description, etc.)
  # @param system_prompt [String] system prompt for the LLM
  # @param character_instance [CharacterInstance, nil] associated character
  # @param metadata [Hash] additional metadata
  # @return [LLMConversation]
  def self.start(purpose:, system_prompt: nil, character_instance: nil, metadata: {})
    create(
      conversation_id: SecureRandom.uuid,
      purpose: purpose,
      system_prompt: system_prompt,
      character_instance_id: character_instance&.id,
      metadata: metadata,
      last_message_at: Time.now
    )
  end

  # Add a message to this conversation
  # @param role [String] 'user', 'assistant', or 'system'
  # @param content [String] message content
  # @param token_count [Integer, nil] token count if known
  # @return [LLMMessage]
  def add_message(role:, content:, token_count: nil)
    msg = add_llm_message(
      role: role,
      content: content,
      token_count: token_count,
      created_at: Time.now
    )
    update(last_message_at: Time.now)
    msg
  end

  # Get conversation history as array for LLM API
  # @param include_system [Boolean] include system prompt as first message
  # @return [Array<Hash>] messages in LLM API format
  def message_history(include_system: false)
    messages = []

    if include_system && system_prompt && !system_prompt.empty?
      messages << { role: 'system', content: system_prompt }
    end

    llm_messages.each do |msg|
      messages << { role: msg.role, content: msg.content }
    end

    messages
  end

  # Get total token count for this conversation
  # @return [Integer]
  def total_tokens
    llm_messages.sum(:token_count) || 0
  end

  # Parse metadata JSONB
  # @return [Hash]
  def parsed_metadata
    return {} if metadata.nil?
    return metadata if metadata.is_a?(Hash)

    JSON.parse(metadata)
  rescue JSON::ParserError
    {}
  end

  # Get the last N messages
  # @param count [Integer] number of messages
  # @return [Array<LLMMessage>]
  def recent_messages(count = 10)
    llm_messages_dataset.order(Sequel.desc(:created_at)).limit(count).all.reverse
  end
end
