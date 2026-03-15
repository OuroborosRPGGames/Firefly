# frozen_string_literal: true

# AbuseCheck tracks content moderation checks for player communications.
#
# Implements a two-tier AI moderation system:
# 1. First pass with Gemini Flash for quick screening
# 2. Second pass with Claude Opus for flagged content verification
#
# Status flow:
#   pending -> gemini_checking -> (flagged|cleared)
#   flagged -> escalated -> (confirmed|cleared)
#
# Examples:
#   check = AbuseCheck.create_for_message(
#     content: "Hello world",
#     message_type: 'say',
#     character_instance: ci
#   )
#   check.status  # => 'pending'
#   check.mark_gemini_result!(flagged: false, confidence: 0.1, reasoning: "Normal greeting")
#   check.status  # => 'cleared'
#
class AbuseCheck < Sequel::Model
  include StatusEnum
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :user
  one_to_many :moderation_actions

  status_enum :status, %w[pending gemini_checking flagged escalated confirmed cleared]
  MESSAGE_TYPES = %w[say emote whisper pm think memo ooc channel].freeze
  ABUSE_CATEGORIES = %w[
    harassment hate_speech threats doxxing spam csam
    immersion_breaking griefing exploit_attempt
    other false_positive
  ].freeze
  SEVERITIES = %w[low medium high critical].freeze
  DETECTION_SOURCES = %w[pre_llm llm].freeze

  # Scopes
  dataset_module do
    def pending
      where(status: 'pending')
    end
  end

  # Create a new abuse check for a message
  #
  # @param content [String] The message content
  # @param message_type [String] Type of message (say, emote, etc.)
  # @param character_instance [CharacterInstance] The sender
  # @param context [Hash] Additional context (room name, recent messages)
  # @return [AbuseCheck]
  def self.create_for_message(content:, message_type:, character_instance:, context: {})
    # IP address may not be available on character_instance; get from context or leave nil
    ip_addr = context[:ip_address] || (character_instance.respond_to?(:ip_address) ? character_instance.ip_address : nil)

    create(
      character_instance_id: character_instance.id,
      user_id: character_instance.character.user_id,
      ip_address: ip_addr,
      message_type: message_type,
      message_content: content,
      message_context: Sequel.pg_jsonb_wrap(context),
      status: 'pending'
    )
  end

  # Get pending checks that need Gemini processing
  #
  # @param limit [Integer]
  # @return [Array<AbuseCheck>]
  def self.pending_gemini_checks(limit: 10)
    where(status: 'pending')
      .order(:created_at)
      .limit(limit)
      .all
  end

  # Get flagged checks that need Claude escalation
  #
  # @param limit [Integer]
  # @return [Array<AbuseCheck>]
  def self.pending_escalation(limit: 10)
    where(status: 'flagged')
      .order(:created_at)
      .limit(limit)
      .all
  end

  # Get recent checks for a user
  #
  # @param user_id [Integer]
  # @param limit [Integer]
  # @return [Array<AbuseCheck>]
  def self.recent_for_user(user_id, limit: 50)
    where(user_id: user_id)
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .all
  end

  # Mark as being processed by Gemini
  #
  # @return [self]
  def start_gemini_check!
    update(status: 'gemini_checking')
    self
  end

  # Record Gemini check result
  #
  # @param flagged [Boolean] Whether Gemini flagged the content
  # @param confidence [Float] Confidence score (0.0-1.0)
  # @param reasoning [String] Explanation from Gemini
  # @param category [String, nil] Abuse category if flagged
  # @return [self]
  def mark_gemini_result!(flagged:, confidence:, reasoning:, category: nil)
    new_status = flagged ? 'flagged' : 'cleared'

    update(
      gemini_flagged: flagged,
      gemini_confidence: confidence,
      gemini_reasoning: reasoning,
      gemini_checked_at: Time.now,
      abuse_category: category,
      status: new_status
    )
    self
  end

  # Mark as being escalated to Claude
  #
  # @return [self]
  def start_escalation!
    update(status: 'escalated')
    self
  end

  # Record Claude verification result
  #
  # @param confirmed [Boolean] Whether Claude confirmed the abuse
  # @param confidence [Float] Confidence score (0.0-1.0)
  # @param reasoning [String] Explanation from Claude
  # @param category [String, nil] Abuse category
  # @param severity [String, nil] Severity level
  # @param processing_time_ms [Integer, nil] Total processing time
  # @return [self]
  def mark_claude_result!(confirmed:, confidence:, reasoning:, category: nil, severity: nil, processing_time_ms: nil)
    new_status = confirmed ? 'confirmed' : 'cleared'

    update(
      claude_confirmed: confirmed,
      claude_confidence: confidence,
      claude_reasoning: reasoning,
      claude_checked_at: Time.now,
      abuse_category: category || abuse_category,
      severity: severity,
      status: new_status,
      processing_time_ms: processing_time_ms
    )
    self
  end

  # Mark as actioned
  #
  # @param action [String] The action taken
  # @return [self]
  def mark_actioned!(action)
    update(action_taken: action)
    self
  end

  # Check if this check requires escalation to Claude
  #
  # @return [Boolean]
  def needs_escalation?
    status == 'flagged'
  end

  # Check if abuse was confirmed
  #
  # @return [Boolean]
  def abuse_confirmed?
    status == 'confirmed' && claude_confirmed == true
  end

  # Check if the check has completed (either cleared or confirmed)
  #
  # @return [Boolean]
  def completed?
    %w[cleared confirmed].include?(status)
  end

  # Get parsed context
  #
  # @return [Hash]
  def parsed_context
    ctx = message_context
    return {} if ctx.nil?

    # Handle both regular Hash and Sequel::Postgres::JSONBHash
    if ctx.respond_to?(:to_h)
      ctx.to_h
    elsif ctx.is_a?(Hash)
      ctx
    else
      {}
    end
  end

  # Check if this was detected by pre-LLM screening
  #
  # @return [Boolean]
  def pre_llm_detected?
    pre_llm_flagged == true
  end

  # Get parsed pre-LLM detection details
  #
  # @return [Hash]
  def parsed_pre_llm_details
    details = pre_llm_details
    return {} if details.nil?

    # Handle both regular Hash and Sequel::Postgres::JSONBHash
    if details.respond_to?(:to_h)
      details.to_h
    elsif details.is_a?(Hash)
      details
    else
      {}
    end
  end

  # Create an abuse check for pre-LLM detected content
  #
  # @param content [String] The message content
  # @param message_type [String] Type of message
  # @param character_instance [CharacterInstance] The sender
  # @param pre_llm_result [Hash] Result from ContentScreeningService
  # @param context [Hash] Additional context
  # @return [AbuseCheck]
  def self.create_for_pre_llm_detection(content:, message_type:, character_instance:, pre_llm_result:, context: {})
    # IP address may not be available on character_instance; get from context or leave nil
    ip_addr = context[:ip_address] || (character_instance.respond_to?(:ip_address) ? character_instance.ip_address : nil)

    create(
      character_instance_id: character_instance.id,
      user_id: character_instance.character.user_id,
      ip_address: ip_addr,
      message_type: message_type,
      message_content: content,
      message_context: Sequel.pg_jsonb_wrap(context),
      status: 'confirmed',  # Pre-LLM detections bypass LLM verification
      pre_llm_flagged: true,
      pre_llm_category: pre_llm_result[:category],
      pre_llm_details: Sequel.pg_jsonb_wrap(pre_llm_result[:details] || {}),
      detection_source: 'pre_llm',
      abuse_category: pre_llm_result[:category],
      severity: pre_llm_result[:severity] || 'medium',
      universe_theme: context[:universe_theme]
    )
  end

  # Format for admin display
  #
  # @return [Hash]
  def to_admin_hash
    {
      id: id,
      user_id: user_id,
      character_instance_id: character_instance_id,
      ip_address: ip_address,
      message_type: message_type,
      message_content: message_content,
      status: status,
      gemini_flagged: gemini_flagged,
      gemini_confidence: gemini_confidence,
      gemini_reasoning: gemini_reasoning,
      gemini_checked_at: gemini_checked_at&.iso8601,
      claude_confirmed: claude_confirmed,
      claude_confidence: claude_confidence,
      claude_reasoning: claude_reasoning,
      claude_checked_at: claude_checked_at&.iso8601,
      abuse_category: abuse_category,
      severity: severity,
      action_taken: action_taken,
      processing_time_ms: processing_time_ms,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
