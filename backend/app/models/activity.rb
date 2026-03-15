# frozen_string_literal: true

# Activity system - requires activities table to exist
# Skip loading if table doesn't exist (development/test without full schema)
return unless DB.table_exists?(:activities)

class Activity < Sequel::Model(:activities)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers
  plugin :timestamps

  ACTIVITY_TYPES = %w[mission competition tcompetition task elimination intersym interasym].freeze
  SHARE_TYPES = %w[public private unique].freeze
  LAUNCH_MODES = %w[creator anyone anchor].freeze

  # Relationships
  many_to_one :creator, class: :Character, key: :created_by
  many_to_one :location_room, class: :Room, key: :location
  many_to_one :locale_room, class: :Room, key: :locale
  many_to_one :universe, class: :Universe, key: :universe_id
  many_to_one :stat_block, class: :StatBlock, key: :stat_block_id

  # Anchor relationships (for competitions)
  many_to_one :anchor_item, class: :Item, key: :anchor_item_id
  many_to_one :anchor_pattern, class: :Pattern, key: :anchor_item_pattern_id

  # Task trigger relationships
  many_to_one :task_trigger_room, class: :Room, key: :task_trigger_room_id

  # Dataset methods for associations (deferred to avoid load-order issues)
  def rounds_dataset
    ActivityRound.where(activity_id: id)
  end

  def rounds
    rounds_dataset.all
  end

  def instances_dataset
    ActivityInstance.where(activity_id: id)
  end

  def instances
    instances_dataset.all
  end

  def actions_dataset
    ActivityAction.where(activity_parent: id)
  end

  def actions
    actions_dataset.all
  end

  def validate
    super
    validates_presence [:name, :activity_type]
    validates_includes ACTIVITY_TYPES, :activity_type, allow_nil: true
    validates_includes SHARE_TYPES, :share_type, allow_nil: true
    validates_includes LAUNCH_MODES, :launch_mode, allow_nil: true
  end

  # Convenience accessors for legacy code expecting aname/adesc/atype
  def aname
    name
  end

  def adesc
    description
  end

  def atype
    activity_type
  end

  def first_round
    rounds_dataset.where(round_number: 1, branch: 0).first
  end

  # Type checks
  def mission?
    atype == 'mission'
  end

  def competition?
    %w[competition tcompetition elimination].include?(atype)
  end

  def team_competition?
    atype == 'tcompetition'
  end

  def task?
    atype == 'task'
  end

  def interpersonal?
    %w[intersym interasym].include?(atype)
  end

  # Status checks
  def public?
    is_public == true
  end

  def emergency?
    is_emergency == true
  end

  def can_run_as_emergency?
    can_emergency == true
  end

  def repeatable?
    repeatable == true
  end

  def pending_approval?
    pending_approval == true
  end

  # Round access
  def round_at(number, branch = 0)
    rounds_dataset.where(round_number: number, branch: branch).first
  end

  def branch_rounds(branch_id)
    rounds_dataset.where(branch: branch_id).order(:round_number).all
  end

  def main_rounds
    branch_rounds(0)
  end

  def total_rounds
    main_rounds.count
  end

  # Stat type for this activity
  def uses_paired_stats?
    stat_type == 'paired'
  end

  # Display
  def display_name
    name
  end

  def type_display
    case atype
    when 'mission' then 'Mission'
    when 'competition' then 'Competition'
    when 'tcompetition' then 'Team Competition'
    when 'task' then 'Task'
    when 'elimination' then 'Elimination'
    when 'intersym' then 'Interpersonal (Symmetric)'
    when 'interasym' then 'Interpersonal (Asymmetric)'
    else atype&.capitalize || 'Unknown'
    end
  end

  # Start a new instance
  def start_instance(room:, initiator: nil, event: nil)
    ActivityInstance.create(
      activity_id: id,
      room_id: room.id,
      event_id: event&.id,
      initiator_id: initiator&.id,
      atype: atype,
      team_name_one: team_name_one,
      team_name_two: team_name_two,
      setup_stage: 1,
      rounds_done: 0,
      branch: 0,
      running: true
    )
  end

  # ============================================
  # Anchor & Launch Mode Methods
  # ============================================

  # Check if this activity is anchored to an item
  def anchored_to_item?
    !anchor_item_id.nil? || !anchor_item_pattern_id.nil?
  end

  # Check if this activity is anchored to a specific room
  def anchored_to_room?
    !location.nil? && !anchored_to_item?
  end

  # Check if a given item can launch this activity
  # @param item [Item] The item to check
  # @return [Boolean]
  def can_launch_from_item?(item)
    return false unless competition?
    return false unless anchored_to_item?

    # Check specific item match
    return true if anchor_item_id == item.id

    # Check pattern match
    return true if anchor_item_pattern_id && item.pattern_id == anchor_item_pattern_id

    false
  end

  # Check if a character can launch this activity
  # @param character [Character] The character trying to launch
  # @param room [Room] The room they're in (optional)
  # @param item [Item] An item they're using (optional)
  # @return [Boolean]
  def can_be_launched_by?(character, room: nil, item: nil)
    case launch_mode
    when 'creator'
      # Only creator can launch
      created_by == character.id
    when 'anyone'
      # Anyone can launch; if location is set, must be in that room
      return true if location.nil?
      room && location == room.id
    when 'anchor'
      # Must use the anchored item
      item && can_launch_from_item?(item)
    else
      # Default to creator-only for safety
      created_by == character.id
    end
  end

  # ============================================
  # Task Trigger Methods
  # ============================================

  # Check if this task should auto-start
  def auto_start_task?
    task? && task_auto_start == true
  end

  # Check if entering a room should trigger this task
  # @param room [Room] The room being entered
  # @return [Boolean]
  def triggers_on_room_entry?(room)
    return false unless task?
    return false unless task_trigger_room_id

    task_trigger_room_id == room.id
  end

  # Find all tasks that trigger when entering a specific room
  # @param room [Room] The room being entered
  # @return [Array<Activity>]
  def self.tasks_for_room_entry(room)
    where(activity_type: 'task', task_trigger_room_id: room.id, task_auto_start: true).all
  end

  # Find all activities anchored to a specific item or pattern
  # @param item [Item] The item to check
  # @return [Array<Activity>]
  def self.anchored_to_item(item)
    ds = where(anchor_item_id: item.id)
    ds = ds.or(anchor_item_pattern_id: item.pattern_id) if item.pattern_id
    ds.all
  end

  # ============================================
  # Builder JSON Serialization
  # ============================================

  # Convert to JSON for the activity builder API
  def to_builder_json
    {
      id: id,
      name: aname,
      description: adesc,
      type: atype,
      type_display: type_display,
      share_type: share_type,
      launch_mode: launch_mode || 'creator',
      location_id: location,
      locale_id: locale,
      anchor_item_id: anchor_item_id,
      anchor_item_pattern_id: anchor_item_pattern_id,
      task_trigger_room_id: task_trigger_room_id,
      task_auto_start: task_auto_start,
      team_name_one: team_name_one,
      team_name_two: team_name_two,
      stat_type: stat_type,
      universe_id: self[:universe_id],
      stat_block_id: self[:stat_block_id],
      is_public: is_public,
      repeatable: repeatable,
      rounds_count: total_rounds
    }
  end
end
