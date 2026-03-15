# frozen_string_literal: true

require_relative '../helpers/canvas_helper'

# Delve represents a procedurally generated dungeon.
# Players progress through with limited time to get loot and extract.
# Features grid-based rooms with fog of war and per-action time costs.
class Delve < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :location
  many_to_one :creator, class: :Character
  one_to_many :delve_rooms
  one_to_many :delve_participants
  one_to_many :delve_monsters

  DIFFICULTIES = %w[easy normal hard nightmare].freeze
  status_enum :status, %w[generating active completed abandoned failed]

  # Time costs for each action type (in seconds) - now from GameConfig
  ACTION_TIMES_SECONDS = GameConfig::Delve::ACTION_TIMES

  ACTION_TIME_SETTING_KEYS = {
    move: 'delve_time_move',
    skill_check: 'delve_time_skill_check',
    recover: 'delve_time_recover',
    focus: 'delve_time_focus',
    study: 'delve_time_study',
    trap_listen: 'delve_time_trap_listen',
    easier: 'delve_time_easier',
    puzzle_attempt: 'delve_time_puzzle_attempt',
    puzzle_hint: ['delve_time_puzzle_help', 'delve_time_puzzle_hint']
  }.freeze

  # Legacy time costs (in minutes) - deprecated
  ACTION_TIMES = {
    move: 1,
    search: 2,
    combat: 5,
    loot: 1
  }.freeze

  # Direction offsets for grid movement (N/S/E/W)
  DIRECTION_OFFSETS = {
    'north' => [0, -1],
    'south' => [0, 1],
    'east' => [1, 0],
    'west' => [-1, 0],
    'n' => [0, -1],
    's' => [0, 1],
    'e' => [1, 0],
    'w' => [-1, 0]
  }.freeze

  # Delegate to CanvasHelper at runtime to avoid load order issues
  def self.opposite_directions
    CanvasHelper::OPPOSITE_DIRECTIONS
  end

  def validate
    super
    validates_presence [:name, :difficulty]
    validates_max_length 100, :name
    validates_includes DIFFICULTIES, :difficulty
    validate_status_enum
  end

  def before_save
    super
    self.difficulty ||= 'normal'
    self.status ||= 'generating'
    self.max_depth ||= 10
    self.time_limit_minutes ||= 60
    self.seed ||= SecureRandom.hex(8)
  end

  def start!
    update(status: 'active', started_at: Time.now)
  end

  def complete!
    update(status: 'completed', completed_at: Time.now)
  end

  def fail!
    update(status: 'failed', completed_at: Time.now)
  end

  def abandon!
    update(status: 'abandoned', completed_at: Time.now)
  end

  def time_remaining
    return nil unless started_at && time_limit_minutes
    elapsed = Time.now - started_at
    remaining = (time_limit_minutes * 60) - elapsed
    [remaining, 0].max
  end

  def time_expired?
    time_remaining && time_remaining <= 0
  end

  def current_depth
    delve_rooms_dataset.where(explored: true).max(:depth) || 0
  end

  def loot_modifier
    # Deeper = better loot
    1.0 + (current_depth * 0.1)
  end

  def add_participant(character_instance)
    DelveParticipant.find_or_create(
      delve_id: id,
      character_instance_id: character_instance.id
    )
  end

  # ====== Grid-Based Room Access ======

  # Get time cost for an action type
  def action_time(action)
    ACTION_TIMES[action.to_sym] || 1
  end

  # Resolve time cost in seconds for delve actions.
  # Prefers admin-configured GameSetting values when available.
  def self.action_time_seconds(action)
    keys = ACTION_TIME_SETTING_KEYS[action.to_sym]
    Array(keys).each do |key|
      configured = GameSetting.integer(key)
      return configured if configured && configured.positive?
    end

    ACTION_TIMES_SECONDS[action.to_sym]
  end

  # Get all rooms on a specific level
  def rooms_on_level(level_num)
    delve_rooms_dataset.where(level: level_num)
  end

  # Get the entrance room for a level
  def entrance_room(level_num = 1)
    rooms_on_level(level_num).where(is_entrance: true).first
  end

  # Get the exit room for a level
  def exit_room(level_num)
    rooms_on_level(level_num).where(is_exit: true).first
  end

  # Get a room by coordinates
  def room_at(level_num, x, y)
    delve_rooms_dataset.where(level: level_num, grid_x: x, grid_y: y).first
  end

  # Get the adjacent room in a direction
  def adjacent_room(from_room, direction)
    offset = direction_offset(direction)
    return nil unless offset

    dx, dy = offset
    room_at(from_room.level, from_room.grid_x + dx, from_room.grid_y + dy)
  end

  # Convert a direction to dx, dy offset
  def direction_offset(direction)
    DIRECTION_OFFSETS[direction.to_s.downcase]
  end

  # Get the opposite direction
  def opposite_direction(direction)
    CanvasHelper.opposite_direction(CanvasHelper.normalize_direction(direction))
  end

  # Generate the next level of the dungeon
  def generate_next_level!
    next_level = (levels_generated || 1) + 1
    DelveGeneratorService.generate_level!(self, next_level)
    update(levels_generated: next_level)
    next_level
  end

  # Check if a level has been generated
  def level_exists?(level_num)
    level_num <= (levels_generated || 1)
  end

  # ====== Party & Participant Management ======

  # Get all active participants in the delve
  def active_participants
    delve_participants_dataset.where(status: 'active').all
  end

  # Get participants currently in a specific room
  def participants_in_room(room)
    delve_participants_dataset.where(
      status: 'active',
      current_delve_room_id: room.id
    ).all
  end

  # Update party size based on current active participants
  def update_party_size!
    update(party_size: active_participants.count)
  end

  # ====== Monster Difficulty Calculation ======

  # Calculate base difficulty for a newly created generic PC
  # Uses PowerCalculatorService with base stats
  def calculate_base_difficulty!
    # Calculate power for a generic PC with base stats
    # PowerCalculatorService.calculate_pc_power expects a character,
    # but we can calculate manually using the base formula
    base_hp = 6  # Default HP
    base_stat = 10  # Default stat value

    # From PowerCalculatorService:
    # hp_factor = hp * WEIGHTS[:hp] (hp * 10)
    # stat_factor = ((str + dex - 20) / 2.0) * WEIGHTS[:damage_bonus] (0 for base stats)
    # dice_factor = 2.5 * 3 = 7.5 (for 2d8)
    hp_factor = base_hp * 10  # 60
    stat_factor = 0  # ((10 + 10 - 20) / 2.0) * 15 = 0
    dice_factor = 7.5

    base_power = hp_factor + stat_factor + dice_factor  # 67.5
    update(base_difficulty: base_power.round)
  end

  # Get monster difficulty for a specific level
  # Level 1: 50% of base × party_size
  # Each level: +20%
  def monster_difficulty_for_level(level)
    base = base_difficulty || 68  # Default if not calculated

    # Get configured multipliers from GameSetting
    base_mult = GameSetting.get('delve_base_monster_multiplier')&.to_f || 0.5
    level_inc = GameSetting.get('delve_monster_level_increase')&.to_f || 0.2

    # Calculate: base × base_mult × party_size × (1 + level_inc × (level - 1))
    party = [party_size || 1, 1].max
    level_mult = 1 + (level_inc * (level - 1))

    (base * base_mult * party * level_mult).round
  end

  # ====== Monster Management ======

  # Get all active monsters in the delve
  def active_monsters
    delve_monsters_dataset.where(is_active: true).all
  end

  # Get active monsters on a specific level
  def monsters_on_level(level)
    delve_monsters_dataset
      .join(:delve_rooms, id: :current_room_id)
      .where(Sequel[:delve_monsters][:is_active] => true)
      .where(Sequel[:delve_rooms][:level] => level)
      .select_all(:delve_monsters)
      .all
  end

  # Get monsters in a specific room
  def monsters_in_room(room)
    delve_monsters_dataset.where(
      is_active: true,
      current_room_id: room.id
    ).all
  end

  # Tick monster movement when players take time-consuming actions
  # Returns array of collision events
  def tick_monster_movement!(time_spent_seconds)
    threshold = GameSetting.integer('delve_monster_move_threshold') || 10
    return [] if time_spent_seconds < threshold

    # Increment counter
    new_counter = (monster_move_counter || 0) + time_spent_seconds
    update(monster_move_counter: new_counter)

    # Move monsters and check for collisions
    collisions = []
    active_monsters.each do |monster|
      next unless monster.should_move?

      move = monster.next_move
      next unless move

      old_room = monster.current_room
      monster.move_to!(move[:room])

      # Check if monster collided with any participants
      participants = participants_in_room(move[:room])
      if participants.any?
        collisions << {
          type: :collision,
          monster: monster,
          room: move[:room],
          participants: participants
        }
      end

      # Note: we intentionally do not emit "passing" encounters here.
      # Without explicit movement-intent tracking, passing detection produces
      # false positives (idle players in the previous room getting ambushed).
    end

    collisions
  end

  # ====== Room Content Access ======

  # Get blocker in a direction from a room
  # Checks both the current room's outgoing direction and the neighbor's reverse direction
  def blocker_at(room, direction)
    dir = CanvasHelper.normalize_direction(direction)
    b = DelveBlocker.first(delve_room_id: room.id, direction: dir)
    return b if b

    # Check reverse direction on neighbor room
    reverse = CanvasHelper.opposite_direction(dir, fallback: nil)
    neighbor = adjacent_room(room, dir)
    neighbor && reverse ? DelveBlocker.first(delve_room_id: neighbor.id, direction: reverse) : nil
  end

  # Get trap in a direction from a room.
  # Checks both the current room's outgoing direction and the neighbor's reverse direction.
  def trap_at(room, direction)
    dir = CanvasHelper.normalize_direction(direction)
    t = DelveTrap.first(delve_room_id: room.id, direction: dir, disabled: false)
    return t if t

    reverse = CanvasHelper.opposite_direction(dir, fallback: nil)
    neighbor = adjacent_room(room, dir)
    neighbor && reverse ? DelveTrap.first(delve_room_id: neighbor.id, direction: reverse, disabled: false) : nil
  end

  # Get unsolved puzzle blocking movement through a direction.
  # Checks both sides of the connection.
  def puzzle_blocking_at(room, direction)
    dir = CanvasHelper.normalize_direction(direction)
    p = DelvePuzzle.first(delve_room_id: room.id, solved: false)
    return p if p && p.blocks_direction?(dir)

    reverse = CanvasHelper.opposite_direction(dir, fallback: nil)
    neighbor = adjacent_room(room, dir)
    return nil unless neighbor && reverse

    p2 = DelvePuzzle.first(delve_room_id: neighbor.id, solved: false)
    p2 && p2.blocks_direction?(reverse) ? p2 : nil
  end

  # Get puzzle in a room
  def puzzle_in_room(room)
    DelvePuzzle.first(delve_room_id: room.id)
  end

  # Get trap in a room
  def trap_in_room(room)
    DelveTrap.first(delve_room_id: room.id)
  end

  # Get treasure in a room
  def treasure_in_room(room)
    DelveTreasure.first(delve_room_id: room.id)
  end
end
