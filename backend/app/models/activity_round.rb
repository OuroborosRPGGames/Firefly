# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_rounds)

class ActivityRound < Sequel::Model(:activity_rounds)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers

  # Expanded round types for Missions and Competitions
  ROUND_TYPES = %w[
    standard
    reflex
    group_check
    branch
    combat
    free_roll
    persuade
    rest
    break
  ].freeze

  # Round types available for competitions only
  COMPETITION_ROUND_TYPES = %w[standard reflex group_check rest].freeze

  # Default timeout is 8 minutes, reflex is 2 minutes
  DEFAULT_TIMEOUT = 480
  REFLEX_TIMEOUT = 120

  # Relationships
  many_to_one :location_room, class: :Room, key: :location
  many_to_one :reflex_stat, class: :Stat, key: :reflex_stat_id
  many_to_one :persuade_stat, class: :Stat, key: :persuade_stat_id

  # Deferred associations (memoized to avoid N+1 queries)
  def activity
    @activity ||= Activity[activity_id]
  end

  def branch_target
    return nil unless branch_to

    ActivityRound[branch_to]
  end

  def validate
    super
    validates_presence [:activity_id, :round_number]
    validates_includes ROUND_TYPES, :rtype, allow_nil: true
  end

  # Type checks
  def standard?
    rtype.nil? || rtype == 'standard'
  end

  def reflex?
    rtype == 'reflex'
  end

  def group_check?
    rtype == 'group_check'
  end

  def combat?
    rtype == 'combat'
  end

  def free_roll?
    rtype == 'free_roll'
  end

  def persuade?
    rtype == 'persuade'
  end

  def rest?
    rtype == 'rest'
  end

  def branch?
    rtype == 'branch'
  end

  def break?
    rtype == 'break'
  end

  # LLM-based rounds require special handling
  def llm_based?
    free_roll? || persuade?
  end

  # Rounds where everyone must roll (no help/recover options)
  def mandatory_roll?
    reflex? || group_check?
  end

  # Rounds with no dice rolling
  def no_roll?
    branch? || rest? || break?
  end

  # Round configuration
  def round_type
    rtype || 'standard'
  end

  def emit_text
    emit
  end

  def success_text
    succ_text
  end

  def failure_text
    fail_text
  end

  def failure_consequence
    fail_con
  end

  def can_fail_repeat?
    fail_repeat == true
  end

  def reverts_to_main?
    revert_main == true
  end

  def can_knockout?
    knockout == true
  end

  def single_solution?
    single_solution == true
  end

  def group_actions?
    group_actions == true
  end

  # Tasks for this round
  def tasks
    return [] unless DB.table_exists?(:activity_tasks)

    ActivityTask.where(activity_round_id: id).order(:task_number).all
  end

  def has_tasks?
    !tasks.empty?
  end
  alias tasks? has_tasks?

  def active_tasks(participant_count)
    tasks.select { |t| t.active_for_count?(participant_count) }
  end

  # Actions available in this round (from round's actions array only)
  def available_actions
    return [] if actions.nil? || actions.empty?

    action_ids_array = actions.to_a.map(&:to_i)
    actions_by_id = ActivityAction.where(id: action_ids_array).all.each_with_object({}) do |action, acc|
      acc[action.id] = action
    end

    # Preserve configured order from the round's `actions` array.
    action_ids_array.filter_map { |id| actions_by_id[id] }
  end

  # All actions: from tasks if present, otherwise from round's actions array.
  # When tasks exist, task actions supersede round-level actions to avoid duplicates.
  def all_actions
    if has_tasks?
      result = []
      tasks.each { |t| result.concat(t.actions) }
      result
    else
      available_actions
    end
  end

  def action_ids
    actions || []
  end

  # Branch choices (for branch rounds)
  def branch_choices
    return [] unless branch?

    choices = []
    choices << { text: branch_choice_one, branch_to: branch_to } if branch_choice_one && !branch_choice_one.empty?
    choices << { text: branch_choice_two, branch_to: nil } if branch_choice_two && !branch_choice_two.empty?
    choices
  end

  # Stat bonuses by role/position
  # Format: sb[role][stat] where role = one/two, stat = one/two/three
  # Note: Only roles 1-2 are supported (roles 3-4 columns were removed as unused)
  def stat_bonus_for(role_number, stat_number)
    role_names = %w[one two]
    stat_names = %w[one two three]

    return 0 unless role_number.between?(1, 2) && stat_number.between?(1, 3)

    column = "sb#{role_names[role_number - 1]}#{stat_names[stat_number - 1]}"
    send(column) || 0
  end

  # Next round in sequence
  def next_round
    activity.round_at(round_number + 1, branch)
  end

  # Previous round in sequence
  def previous_round
    return nil if round_number <= 1

    activity.round_at(round_number - 1, branch)
  end

  # Display
  def display_name
    return self[:name] if self[:name] && !self[:name].to_s.strip.empty?

    "Round #{round_number}#{branch > 0 ? " (Branch #{branch})" : ''}"
  end

  def difficulty_class
    # Ravencroft doesn't have a DC field, it uses different mechanics
    # We'll calculate from the activity's enemy score
    nil
  end

  # ========================================
  # New Round Type Configuration Methods
  # ========================================

  # Timeout in seconds (reflex rounds are faster)
  def round_timeout
    return timeout_seconds if timeout_seconds && timeout_seconds > 0

    reflex? ? REFLEX_TIMEOUT : DEFAULT_TIMEOUT
  end

  # Reflex round: stat to test
  def reflex_stat_name
    reflex_stat&.name || 'Agility'
  end

  # Combat round: NPC archetypes to spawn
  def combat_npcs
    return [] unless combat?
    return [] if combat_npc_ids.nil? || combat_npc_ids.empty?

    NpcArchetype.where(id: combat_npc_ids.to_a).all
  end

  def finale?
    combat_is_finale == true
  end

  # Persuade round configuration
  def persuade_dc(modifier = 0)
    (persuade_base_dc || 15) + modifier
  end

  def persuade_stat_name
    persuade_stat&.name || 'Charisma'
  end

  # Branch round: enhanced choices from JSONB
  def expanded_branch_choices
    return [] unless branch?

    # First try JSONB column (check for any array-like response including JSONBArray)
    bc = self[:branch_choices]
    if bc.respond_to?(:each) && bc.respond_to?(:any?) && bc.any?
      return bc.map do |choice|
        {
          text: choice['text'],
          branch_to_round_id: choice['branch_to_round_id'] || choice['leads_to_branch'],
          description: choice['description']
        }
      end
    end

    # Fall back to legacy columns
    choices = []
    if branch_choice_one && !branch_choice_one.empty?
      choices << { text: branch_choice_one, branch_to_round_id: branch_to }
    end
    if branch_choice_two && !branch_choice_two.empty?
      choices << { text: branch_choice_two, branch_to_round_id: nil }
    end
    choices
  end

  # Failure branch target
  def failure_branch_target
    return nil unless fail_branch_to

    ActivityRound[fail_branch_to]
  end

  # Failure consequence type (uses existing fail_con column)
  # Values: none, difficulty, injury, harder_finale, branch
  def fail_consequence_type
    fail_con || 'none'
  end

  def applies_difficulty_penalty?
    fail_consequence_type == 'difficulty'
  end

  def applies_injury?
    fail_consequence_type == 'injury'
  end

  def makes_finale_harder?
    fail_consequence_type == 'harder_finale'
  end

  def branches_on_failure?
    fail_consequence_type == 'branch' && !fail_branch_to.nil?
  end

  # ============================================
  # Room Configuration (Migration 144)
  # ============================================

  # Room assigned specifically to this round
  many_to_one :round_room, class: :Room, key: :round_room_id

  # Battle map room for combat rounds
  many_to_one :battle_map_room, class: :Room, key: :battle_map_room_id

  # Get the effective room for this round
  # Returns round-specific room if set, otherwise activity's location
  def effective_room
    return round_room if round_room_id && !use_activity_room
    return activity&.location_room if activity

    nil
  end

  # Check if using activity's room vs custom room
  def uses_activity_room?
    use_activity_room != false
  end

  # Check if this round has a custom room assigned
  def has_custom_room?
    !round_room_id.nil? && !use_activity_room
  end
  alias custom_room? has_custom_room?

  # ============================================
  # Media Configuration (Migration 144)
  # ============================================

  MEDIA_TYPES = %w[youtube audio].freeze
  MEDIA_DISPLAY_MODES = %w[thin box].freeze
  MEDIA_DURATION_MODES = %w[round activity until_replaced].freeze

  # Check if this round has media attached
  def has_media?
    !media_url.nil? && !media_url.empty?
  end
  alias media? has_media?

  # Media type detection
  def youtube?
    return true if media_type == 'youtube'
    return false unless media_url

    media_url.match?(/youtube\.com|youtu\.be/i)
  end

  def audio?
    return true if media_type == 'audio'
    return false unless media_url

    media_url.match?(/\.mp3|\.wav|\.ogg|\.m4a/i)
  end

  # Detect media type from URL if not explicitly set
  def detected_media_type
    return media_type if media_type && !media_type.empty?
    return 'youtube' if youtube?
    return 'audio' if audio?

    nil
  end

  # Display mode: 'thin' for audio strip, 'box' for video player
  def media_display
    media_display_mode || (youtube? && !audio? ? 'box' : 'thin')
  end

  # Duration mode: how long media plays
  def media_duration
    media_duration_mode || 'round'
  end

  # Should media stop when round ends?
  def media_stops_on_round_end?
    media_duration == 'round'
  end

  # Should media continue until activity ends?
  def media_continues_to_activity_end?
    media_duration == 'activity'
  end

  # Should media continue until replaced by another?
  def media_continues_until_replaced?
    media_duration == 'until_replaced'
  end

  # Generate embed URL for YouTube videos
  def youtube_embed_url
    return nil unless youtube? && media_url

    # Extract video ID from various YouTube URL formats
    video_id = extract_youtube_video_id(media_url)
    return nil unless video_id

    "https://www.youtube.com/embed/#{video_id}?autoplay=1"
  end

  # Extract YouTube video ID from URL
  def extract_youtube_video_id(url)
    return nil unless url

    # Match youtube.com/watch?v=ID
    if url =~ /youtube\.com\/watch\?v=([^&]+)/
      return ::Regexp.last_match(1)
    end

    # Match youtu.be/ID
    if url =~ /youtu\.be\/([^?]+)/
      return ::Regexp.last_match(1)
    end

    # Match youtube.com/embed/ID
    if url =~ /youtube\.com\/embed\/([^?]+)/
      return ::Regexp.last_match(1)
    end

    nil
  end

  # ============================================
  # Canvas Positioning (Migration 144)
  # ============================================

  # Get canvas position as hash
  def canvas_position
    { x: canvas_x || 0, y: canvas_y || 0 }
  end

  # Set canvas position
  def set_canvas_position(x, y)
    self.canvas_x = x.to_i
    self.canvas_y = y.to_i
  end

  # ============================================
  # Combat Configuration (Migration 144)
  # ============================================

  COMBAT_DIFFICULTIES = %w[easy normal hard deadly].freeze

  # Get combat difficulty setting
  def combat_difficulty_level
    combat_difficulty || 'normal'
  end

  # Check if this is a finale battle
  def finale_battle?
    finale? || combat_is_finale == true
  end

  # ============================================
  # Builder JSON Serialization
  # ============================================

  # Convert to JSON for the activity builder API
  def to_builder_json
    {
      id: id,
      activity_id: activity_id,
      round_number: round_number,
      branch: branch,
      round_type: round_type,
      name: self[:name],
      emit: emit,
      success_text: succ_text,
      failure_text: fail_text,
      failure_consequence: fail_con,
      fail_repeat: fail_repeat,
      knockout: knockout,
      single_solution: single_solution,
      group_actions: group_actions,

      # Room configuration
      round_room_id: round_room_id,
      use_activity_room: use_activity_room,
      effective_room_id: effective_room&.id,
      effective_room_name: effective_room&.name,

      # Media configuration
      media_url: media_url,
      media_type: detected_media_type,
      media_display_mode: media_display,
      media_duration_mode: media_duration,
      has_media: has_media?,
      youtube_embed_url: youtube_embed_url,

      # Canvas position
      canvas_x: canvas_x || 0,
      canvas_y: canvas_y || 0,

      # Combat configuration
      battle_map_room_id: battle_map_room_id,
      combat_difficulty: combat_difficulty_level,
      combat_is_finale: finale_battle?,
      combat_npc_ids: combat_npc_ids,

      # Branch configuration
      branch_to: branch_to,
      branch_choice_one: branch_choice_one,
      branch_choice_two: branch_choice_two,
      branch_choices: expanded_branch_choices,
      fail_branch_to: fail_branch_to,

      # Reflex/persuade configuration
      reflex_stat_id: reflex_stat_id,
      persuade_stat_id: persuade_stat_id,
      persuade_stat_ids: persuade? ? (self[:stat_set_a].to_a rescue [persuade_stat_id].compact) : [],
      persuade_base_dc: persuade_base_dc,
      persuade_npc_name: self[:persuade_npc_name],
      persuade_npc_personality: self[:persuade_npc_personality],
      persuade_goal: self[:persuade_goal],

      # Free roll
      free_roll_context: self[:free_roll_context],

      # Stat sets
      stat_set_a: (self[:stat_set_a].to_a rescue []),
      stat_set_b: (self[:stat_set_b].to_a rescue []),

      # Timeouts
      timeout_seconds: round_timeout,

      # Tasks
      tasks: tasks.map(&:to_builder_json),
      has_tasks: has_tasks?,

      # Metadata
      display_name: display_name,
      is_branch: branch?,
      is_combat: combat?,
      is_reflex: reflex?,
      has_custom_room: has_custom_room?
    }
  end

  # Compact JSON for canvas node rendering
  def to_node_json
    {
      id: id,
      round_number: round_number,
      branch: branch,
      round_type: round_type,
      display_name: display_name,
      canvas_x: canvas_x || 0,
      canvas_y: canvas_y || 0,
      has_media: has_media?,
      has_custom_room: has_custom_room?,
      is_finale: finale_battle?,
      branch_to: branch_to,
      fail_branch_to: fail_branch_to
    }
  end
end
