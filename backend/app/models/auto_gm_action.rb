# frozen_string_literal: true

# AutoGmAction represents an individual action taken by the AI Game Master.
# Actions include narrative emits, roll requests, character movement,
# NPC spawning, secret reveals, and session resolution.
class AutoGmAction < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, create: :created_at, update: false

  # Associations
  many_to_one :session, class: :AutoGmSession, key: :session_id
  many_to_one :target_character, class: :Character, key: :target_character_id
  many_to_one :target_room, class: :Room, key: :target_room_id

  # Action types
  ACTION_TYPES = %w[
    emit
    roll_request
    move_characters
    spawn_npc
    spawn_item
    reveal_secret
    trigger_twist
    advance_stage
    start_climax
    resolve_session
    player_action
  ].freeze

  status_enum :status, %w[pending completed failed]

  def validate
    super
    validates_presence [:session_id, :action_type, :sequence_number]
    validates_includes ACTION_TYPES, :action_type if action_type
    validates_unique [:session_id, :sequence_number] if session_id && sequence_number
    validate_status_enum
  end

  def before_create
    super
    self.status ||= 'pending'
    self.action_data ||= {}
  end

  # ========================================
  # Action Type Checks
  # ========================================

  def emit?
    action_type == 'emit'
  end

  def roll_request?
    action_type == 'roll_request'
  end

  def move_characters?
    action_type == 'move_characters'
  end

  def spawn_npc?
    action_type == 'spawn_npc'
  end

  def spawn_item?
    action_type == 'spawn_item'
  end

  def reveal_secret?
    action_type == 'reveal_secret'
  end

  def trigger_twist?
    action_type == 'trigger_twist'
  end

  def advance_stage?
    action_type == 'advance_stage'
  end

  def start_climax?
    action_type == 'start_climax'
  end

  def resolve_session?
    action_type == 'resolve_session'
  end

  # ========================================
  # Lifecycle
  # ========================================

  # Mark action as completed
  def complete!
    update(status: 'completed')
  end

  # Mark action as failed with optional error info
  # @param error [String, nil] Error message
  def fail!(error = nil)
    data = action_data || {}
    data['error'] = error if error
    update(status: 'failed', action_data: data)
  end

  # ========================================
  # Action Data Accessors
  # ========================================

  # For roll_request actions
  def roll_character_id
    action_data&.dig('character_id') || target_character_id
  end

  def roll_type
    action_data&.dig('roll_type')
  end

  def roll_dc
    action_data&.dig('roll_dc') || action_data&.dig('dc')
  end

  def roll_stat
    action_data&.dig('roll_stat') || action_data&.dig('stat')
  end

  # For move_characters actions
  def move_character_ids
    action_data&.dig('character_ids') || action_data&.dig('target_character_ids') || action_data&.dig('target_characters') || []
  end

  def destination_room_id
    action_data&.dig('destination_room_id')
  end

  def movement_adverb
    action_data&.dig('movement_adverb') || action_data&.dig('adverb') || 'walk'
  end

  # For spawn_npc actions
  def npc_archetype_id
    action_data&.dig('archetype_id')
  end

  def npc_archetype_hint
    action_data&.dig('npc_archetype_hint')
  end

  def spawn_room_id
    action_data&.dig('room_id')
  end

  def npc_disposition
    action_data&.dig('npc_disposition') || action_data&.dig('disposition')
  end

  def npc_name_hint
    action_data&.dig('name_hint') || action_data&.dig('npc_name')
  end

  # For spawn_item actions
  def item_pattern_id
    action_data&.dig('pattern_id')
  end

  def item_description
    action_data&.dig('item_description') || action_data&.dig('description')
  end

  # For reveal_secret actions
  def secret_index
    action_data&.dig('secret_index') || 0
  end

  # For advance_stage actions
  def target_stage
    action_data&.dig('target_stage')
  end

  # For resolve_session actions
  def resolution_type
    action_data&.dig('resolution_type')
  end

  # ========================================
  # Display Helpers
  # ========================================

  # Get a human-readable summary of this action
  # @return [String]
  def summary
    case action_type
    when 'emit'
      text = emit_text || ''
      text.length > 100 ? "#{text[0..97]}..." : text
    when 'roll_request'
      "Request #{roll_type} roll (DC #{roll_dc})"
    when 'move_characters'
      room = Room[destination_room_id]
      "Move characters to #{room&.name || 'unknown'}"
    when 'spawn_npc'
      "Spawn NPC: #{npc_archetype_hint || 'unknown'}"
    when 'spawn_item'
      "Spawn item: #{item_description || 'unknown'}"
    when 'reveal_secret'
      "Reveal secret ##{secret_index}"
    when 'trigger_twist'
      'Trigger the twist'
    when 'advance_stage'
      "Advance to stage #{target_stage}"
    when 'start_climax'
      'Begin climax'
    when 'resolve_session'
      "Resolve: #{resolution_type}"
    else
      action_type
    end
  end

  # ========================================
  # Class Methods
  # ========================================

  class << self
    # Create an action with a race-safe sequence number allocation.
    # Uses a row lock on the parent session so concurrent writers serialize sequence assignment.
    # @param session_id [Integer]
    # @param attributes [Hash]
    # @return [AutoGmAction]
    def create_with_next_sequence(session_id:, attributes:)
      safe_attrs = (attributes || {}).dup
      safe_attrs.delete(:session_id)
      safe_attrs.delete(:sequence_number)

      DB.transaction do
        DB[:auto_gm_sessions].where(id: session_id).for_update.first
        next_seq = (where(session_id: session_id).max(:sequence_number) || 0) + 1
        create(safe_attrs.merge(session_id: session_id, sequence_number: next_seq))
      end
    end

    # Create an emit action
    # @param session [AutoGmSession]
    # @param text [String]
    # @param reasoning [String, nil]
    # @return [AutoGmAction]
    def create_emit(session, text, reasoning: nil, thinking_tokens: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'emit',
          emit_text: text,
          ai_reasoning: reasoning,
          thinking_tokens_used: thinking_tokens
        }
      )
    end

    # Create a roll request action
    # @param session [AutoGmSession]
    # @param character_id [Integer]
    # @param roll_type [String]
    # @param dc [Integer]
    # @param stat [String, nil]
    # @return [AutoGmAction]
    def create_roll_request(session, character_id:, roll_type:, dc:, stat: nil, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'roll_request',
          target_character_id: character_id,
          action_data: { character_id: character_id, roll_type: roll_type, dc: dc, stat: stat },
          ai_reasoning: reasoning
        }
      )
    end

    # Create a move characters action
    # @param session [AutoGmSession]
    # @param character_ids [Array<Integer>]
    # @param destination_room_id [Integer]
    # @param adverb [String]
    # @return [AutoGmAction]
    def create_move(session, character_ids:, destination_room_id:, adverb: 'walk', reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'move_characters',
          target_room_id: destination_room_id,
          action_data: { character_ids: character_ids, destination_room_id: destination_room_id, adverb: adverb },
          ai_reasoning: reasoning
        }
      )
    end

    # Create a spawn NPC action
    # @param session [AutoGmSession]
    # @param archetype_hint [String]
    # @param room_id [Integer, nil]
    # @param disposition [String, nil]
    # @return [AutoGmAction]
    def create_spawn_npc(session, archetype_hint:, room_id: nil, disposition: nil, name_hint: nil, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'spawn_npc',
          target_room_id: room_id || session.current_room_id,
          action_data: {
            npc_archetype_hint: archetype_hint,
            room_id: room_id || session.current_room_id,
            disposition: disposition,
            name_hint: name_hint
          },
          ai_reasoning: reasoning
        }
      )
    end

    # Create a reveal secret action
    # @param session [AutoGmSession]
    # @param secret_index [Integer]
    # @return [AutoGmAction]
    def create_reveal_secret(session, secret_index:, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'reveal_secret',
          action_data: { secret_index: secret_index },
          ai_reasoning: reasoning
        }
      )
    end

    # Create a trigger twist action
    # @param session [AutoGmSession]
    # @return [AutoGmAction]
    def create_trigger_twist(session, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'trigger_twist',
          ai_reasoning: reasoning
        }
      )
    end

    # Create an advance stage action
    # @param session [AutoGmSession]
    # @param target_stage [Integer, nil]
    # @return [AutoGmAction]
    def create_advance_stage(session, target_stage: nil, reasoning: nil)
      target = target_stage || (session.current_stage + 1)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'advance_stage',
          action_data: { target_stage: target },
          ai_reasoning: reasoning
        }
      )
    end

    # Create a start climax action
    # @param session [AutoGmSession]
    # @return [AutoGmAction]
    def create_start_climax(session, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'start_climax',
          ai_reasoning: reasoning
        }
      )
    end

    # Create a resolve session action
    # @param session [AutoGmSession]
    # @param resolution_type [String] success, failure
    # @return [AutoGmAction]
    def create_resolve(session, resolution_type:, reasoning: nil)
      create_with_next_sequence(
        session_id: session.id,
        attributes: {
          action_type: 'resolve_session',
          action_data: { resolution_type: resolution_type },
          ai_reasoning: reasoning
        }
      )
    end
  end
end
