# frozen_string_literal: true

require_relative '../helpers/canvas_helper'

# DelveMonster represents a roving monster that moves through the dungeon.
# Monsters move when players take actions that cost 10+ seconds.
return unless DB.table_exists?(:delve_monsters)

class DelveMonster < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve
  many_to_one :current_room, class: :DelveRoom

  MONSTER_TYPES = %w[rat spider goblin skeleton orc troll ogre demon dragon].freeze

  def validate
    super
    validates_presence [:delve_id, :current_room_id, :monster_type]
    validates_includes MONSTER_TYPES, :monster_type if monster_type
  end

  def before_save
    super
    self.hp ||= max_hp || 6
    self.max_hp ||= 6
    self.is_active = true if is_active.nil?
  end

  # ====== State Checks ======

  def active?
    is_active == true
  end

  def alive?
    (hp || 0) > 0
  end

  def dead?
    !alive?
  end

  def lurking?
    self[:lurking] == true
  end

  # ====== Movement ======

  # Delegate to CanvasHelper for direction constants (canonical source)
  DIRECTION_ARROWS = CanvasHelper::DIRECTION_ARROWS
  REVERSE_DIRECTIONS = CanvasHelper::OPPOSITE_DIRECTIONS

  # Check if monster should move (50% chance)
  # @param rng [Random] optional random generator for testing
  def should_move?(rng = nil)
    return false if lurking?

    rng ||= Random.new
    rng.rand < 0.5
  end

  # Get valid rooms this monster can move to
  # Excludes exits blocked by blockers and rooms containing other monsters
  # (unless the player is there — monsters can join fights)
  def available_moves
    return [] unless current_room

    current_room.available_exits.filter_map do |direction|
      next if direction == 'down' # Monsters don't use stairs
      adjacent = delve.adjacent_room(current_room, direction)
      next unless adjacent

      # Skip exits blocked by uncleared blockers
      blocker = DelveBlocker.first(delve_room_id: current_room.id, direction: direction, cleared: false)
      next if blocker

      # Also check reverse direction blocker (blocker on adjacent room blocking back this way)
      reverse_dir = REVERSE_DIRECTIONS[direction]
      reverse_blocker = reverse_dir && DelveBlocker.first(delve_room_id: adjacent.id, direction: reverse_dir, cleared: false)
      next if reverse_blocker

      # Skip exits blocked by unsolved puzzles
      puzzle = DelvePuzzle.first(delve_room_id: current_room.id, solved: false)
      next if puzzle && puzzle.respond_to?(:blocks_direction?) && puzzle.blocks_direction?(direction)

      # Skip rooms with other active monsters (unless players are there)
      other_monsters = delve.monsters_in_room(adjacent).reject { |m| m.id == id }
      has_players = delve.participants_in_room(adjacent).any?
      next if other_monsters.any? && !has_players

      { direction: direction, room: adjacent }
    end
  end

  # Pick an initial random direction from available moves
  # @param rng [Random] optional random generator for testing
  def pick_direction!(rng: Random.new)
    moves = available_moves
    if moves.any?
      move = moves.sample(random: rng)
      update(movement_direction: move[:direction])
    else
      update(movement_direction: nil)
    end
  end

  # Get the next move using wall-bounce pathing:
  # - Continue in current direction if possible
  # - On wall: pick a new direction (avoid backtracking if possible)
  # - Returns { direction:, room: } or nil
  # @param rng [Random] optional random generator for testing
  def next_move(rng: Random.new)
    return nil if lurking?

    moves = available_moves
    return nil if moves.empty?

    current_dir = self[:movement_direction]
    if current_dir
      # Try to continue in current direction
      forward = moves.find { |m| m[:direction] == current_dir }
      if forward
        return forward
      else
        # Wall hit — pick new direction, avoid reverse if possible
        reverse = REVERSE_DIRECTIONS[current_dir]
        non_reverse = moves.reject { |m| m[:direction] == reverse }
        chosen = non_reverse.any? ? non_reverse.sample(random: rng) : moves.sample(random: rng)
        update(movement_direction: chosen[:direction])
        return chosen
      end
    end

    # No direction set — pick random
    chosen = moves.sample(random: rng)
    update(movement_direction: chosen[:direction])
    chosen
  end

  # Unicode arrow for current movement direction
  def direction_arrow
    DIRECTION_ARROWS[self[:movement_direction]]
  end

  # Move to an adjacent room
  # @param room [DelveRoom] the target room
  def move_to!(room)
    update(
      current_room_id: room.id,
      last_moved_at: Time.now
    )
  end

  # Deactivate monster (killed or fled)
  def deactivate!
    update(is_active: false)
  end

  # ====== Combat ======

  # Take damage from combat
  # @param amount [Integer] damage amount
  def take_damage!(amount)
    new_hp = [(hp || 0) - amount, 0].max
    update(hp: new_hp)

    deactivate! if new_hp <= 0
  end

  # Get display name for combat
  def display_name
    monster_type.to_s.capitalize
  end

  # Get difficulty rating text
  def difficulty_text
    case difficulty_value
    when 0..5 then 'weak'
    when 6..10 then 'average'
    when 11..15 then 'dangerous'
    when 16..20 then 'deadly'
    else 'legendary'
    end
  end
end
