# frozen_string_literal: true

# AutoGmSummary stores hierarchical summaries for context compression.
# Summaries at lower levels (events) get rolled up into higher levels
# (scenes, acts, session) to maintain context while managing token usage.
class AutoGmSummary < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, create: :created_at, update: false

  # Associations
  many_to_one :session, class: :AutoGmSession, key: :session_id
  many_to_one :embedding, class: :Embedding, key: :embedding_id

  # Abstraction levels
  LEVEL_EVENTS = 1   # Individual events (5-10 actions)
  LEVEL_SCENE = 2    # Scene summary (multiple event summaries)
  LEVEL_ACT = 3      # Act summary (multiple scene summaries)
  LEVEL_SESSION = 4  # Full session summary

  LEVELS = [LEVEL_EVENTS, LEVEL_SCENE, LEVEL_ACT, LEVEL_SESSION].freeze
  LEVEL_NAMES = {
    LEVEL_EVENTS => 'events',
    LEVEL_SCENE => 'scene',
    LEVEL_ACT => 'act',
    LEVEL_SESSION => 'session'
  }.freeze

  # Thresholds for triggering abstraction
  # Note: These values are mirrored in GameConfig::AutoGm::COMPRESSION
  # Keep in sync when adjusting balance
  ABSTRACTION_THRESHOLDS = {
    LEVEL_EVENTS => GameConfig::AutoGm::COMPRESSION[:events_per_scene],
    LEVEL_SCENE => GameConfig::AutoGm::COMPRESSION[:scenes_per_act],
    LEVEL_ACT => GameConfig::AutoGm::COMPRESSION[:acts_per_session]
  }.freeze

  def validate
    super
    validates_presence [:session_id, :content, :abstraction_level]
    validates_includes LEVELS, :abstraction_level if abstraction_level
  end

  def before_create
    super
    self.abstraction_level ||= LEVEL_EVENTS
    self.importance ||= 0.5
    self.abstracted ||= false
  end

  # ========================================
  # Level Checks
  # ========================================

  def events_level?
    abstraction_level == LEVEL_EVENTS
  end

  def scene_level?
    abstraction_level == LEVEL_SCENE
  end

  def act_level?
    abstraction_level == LEVEL_ACT
  end

  def session_level?
    abstraction_level == LEVEL_SESSION
  end

  # Get human-readable level name
  # @return [String]
  def level_name
    LEVEL_NAMES[abstraction_level] || 'unknown'
  end

  # ========================================
  # Abstraction State
  # ========================================

  # Check if this summary has been rolled up into a higher level
  # @return [Boolean]
  def abstracted?
    abstracted == true
  end

  # Check if this summary can be abstracted further
  # @return [Boolean]
  def can_abstract?
    !abstracted? && abstraction_level < LEVEL_SESSION
  end

  # Mark as abstracted (rolled up into higher level)
  def mark_abstracted!
    update(abstracted: true)
  end

  # ========================================
  # Embedding Helpers
  # ========================================

  # Check if this summary has an embedding
  # @return [Boolean]
  def has_embedding?
    !embedding_id.nil?
  end
  alias embedding? has_embedding?

  # Create embedding for this summary
  # @return [Embedding, nil]
  def create_embedding!
    return embedding if has_embedding?

    emb = EmbeddingService.create_for(self, content)
    update(embedding_id: emb.id) if emb
    emb
  end

  # ========================================
  # Display Helpers
  # ========================================

  # Get a truncated preview of the content
  # @param max_length [Integer]
  # @return [String]
  def preview(max_length: 100)
    return '' unless content

    content.length > max_length ? "#{content[0..max_length - 4]}..." : content
  end

  # ========================================
  # Class Methods
  # ========================================

  class << self
    # Create an event-level summary
    # @param session [AutoGmSession]
    # @param content [String]
    # @param importance [Float]
    # @return [AutoGmSummary]
    def create_events_summary(session, content, importance: 0.5)
      create(
        session_id: session.id,
        abstraction_level: LEVEL_EVENTS,
        content: content,
        importance: importance
      )
    end

    # Create a scene-level summary
    # @param session [AutoGmSession]
    # @param content [String]
    # @param importance [Float]
    # @return [AutoGmSummary]
    def create_scene_summary(session, content, importance: 0.6)
      create(
        session_id: session.id,
        abstraction_level: LEVEL_SCENE,
        content: content,
        importance: importance
      )
    end

    # Create an act-level summary
    # @param session [AutoGmSession]
    # @param content [String]
    # @param importance [Float]
    # @return [AutoGmSummary]
    def create_act_summary(session, content, importance: 0.7)
      create(
        session_id: session.id,
        abstraction_level: LEVEL_ACT,
        content: content,
        importance: importance
      )
    end

    # Create a session-level summary
    # @param session [AutoGmSession]
    # @param content [String]
    # @param importance [Float]
    # @return [AutoGmSummary]
    def create_session_summary(session, content, importance: 0.9)
      create(
        session_id: session.id,
        abstraction_level: LEVEL_SESSION,
        content: content,
        importance: importance
      )
    end

    # Get unabstracted summaries at a level for a session
    # @param session [AutoGmSession]
    # @param level [Integer]
    # @return [Dataset]
    def unabstracted_at_level(session, level)
      where(session_id: session.id, abstraction_level: level, abstracted: false)
        .order(:created_at)
    end

    # Check if abstraction is needed at a level
    # @param session [AutoGmSession]
    # @param level [Integer]
    # @return [Boolean]
    def needs_abstraction?(session, level)
      threshold = ABSTRACTION_THRESHOLDS[level]
      return false unless threshold

      unabstracted_at_level(session, level).count >= threshold
    end

    # Get the best summary for context (highest level, most recent)
    # @param session [AutoGmSession]
    # @return [AutoGmSummary, nil]
    def best_for_context(session)
      where(session_id: session.id)
        .order(Sequel.desc(:abstraction_level), Sequel.desc(:created_at))
        .first
    end

    # Get all summaries for a session, organized by level
    # @param session [AutoGmSession]
    # @return [Hash<Integer, Array<AutoGmSummary>>]
    def by_level(session)
      all_summaries = where(session_id: session.id).order(:created_at).all
      all_summaries.group_by(&:abstraction_level)
    end

    # Get summaries that need embeddings
    # @return [Dataset]
    def needing_embeddings
      where(embedding_id: nil)
    end
  end
end
