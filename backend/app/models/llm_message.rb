# frozen_string_literal: true

# LLMMessage represents a single message in an LLM conversation
#
# Messages have roles: 'user' (from player), 'assistant' (from LLM), or 'system'
#
class LLMMessage < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :llm_conversation, class: 'LLMConversation'

  ROLES = %w[user assistant system].freeze

  def validate
    super
    validates_presence [:llm_conversation_id, :role, :content]
    validates_includes ROLES, :role
  end

  # Check if this is a user message
  def user?
    role == 'user'
  end

  # Check if this is an assistant (LLM) message
  def assistant?
    role == 'assistant'
  end

  # Check if this is a system message
  def system?
    role == 'system'
  end

  # Convert to hash for LLM API
  # @return [Hash]
  def to_api_format
    { role: role, content: content }
  end
end
