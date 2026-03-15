# frozen_string_literal: true

# DelveRoom represents a room within a procedural delve.
# Rooms are positioned on a grid and can contain monsters, traps, and loot.
class DelveRoom < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve
  many_to_one :parent_room, class: :DelveRoom
  many_to_one :room, class: :Room, key: :room_id
  one_to_many :child_rooms, class: :DelveRoom, key: :parent_room_id

  ROOM_TYPES = %w[corridor corner branch terminal].freeze

  # Descriptions for each room shape
  ROOM_DESCRIPTIONS = {
    'corridor' => 'A narrow stone corridor stretches before you.',
    'corner' => 'The passage turns sharply here.',
    'branch' => 'A spacious chamber with rough-hewn walls.',
    'terminal' => 'A dead-end chamber. The walls close in around you.'
  }.freeze

  def validate
    super
    validates_presence [:delve_id, :room_type, :depth]
    validates_includes ROOM_TYPES, :room_type
  end

  def before_save
    super
    self.explored ||= false
    self.cleared ||= false
    self.depth ||= 0
  end

  def explore!
    update(explored: true, explored_at: Time.now)
  end

  def clear!
    update(cleared: true, cleared_at: Time.now)
  end

  def explored?
    explored == true
  end

  def cleared?
    cleared == true
  end

  def dangerous?
    has_monster? || DelveTrap.where(delve_room_id: id, disabled: false).any?
  end

  def has_loot?
    has_treasure == true
  end
  alias loot? has_loot?

  def is_exit?
    is_exit == true
  end
  alias exit_room? is_exit?

  # Compatibility helper used by delve command dashboards/quickmenus.
  # Exit rooms always have stairs to descend.
  def has_stairs_down?
    is_exit?
  end
  alias stairs_down? has_stairs_down?

  def boss?
    is_boss == true
  end

  # Generate exits (adjacent rooms) - legacy tree-based
  def exits
    child_rooms_dataset.order(:direction)
  end

  def exit_directions
    child_rooms_dataset.select_map(:direction)
  end

  def has_exit?(direction)
    child_rooms_dataset.where(direction: direction).any?
  end

  # ====== Grid-Based Methods ======

  # Get grid position as array [x, y]
  def position
    [grid_x, grid_y]
  end

  # Get unique coordinate key for this room
  def coordinate_key
    "#{level}:#{grid_x},#{grid_y}"
  end

  # Get available exits based on adjacent rooms in the grid
  def available_exits
    return [] unless delve

    exits_list = []

    # Check each cardinal direction for adjacent rooms
    [['north', 0, -1], ['south', 0, 1], ['east', 1, 0], ['west', -1, 0]].each do |dir, dx, dy|
      adjacent = delve.room_at(level, grid_x + dx, grid_y + dy)
      exits_list << dir if adjacent
    end

    # Add stairs down if this is the exit room
    exits_list << 'down' if is_exit

    exits_list
  end

  # Get the adjacent room in a given direction
  def adjacent_room(direction)
    return nil unless delve
    offsets = { 'north' => [0, -1], 'south' => [0, 1], 'east' => [1, 0], 'west' => [-1, 0] }
    dx, dy = offsets[direction.to_s.downcase]
    return nil unless dx
    delve.room_at(level, grid_x + dx, grid_y + dy)
  end

  # Check if a specific direction is available
  def can_go?(direction)
    available_exits.include?(direction.to_s.downcase)
  end

  # ====== Room Description ======

  # Generate description text for this room
  def description_text
    parts = []

    # Base description
    base = ROOM_DESCRIPTIONS[room_type] || 'A dark chamber.'
    parts << base

    # Monster status
    if monster_cleared
      parts << 'Signs of recent combat litter the floor.'
    elsif monster_type && !monster_type.empty?
      parts << "[DANGER] A #{monster_type} lurks here!"
    end

    # Treasure indication
    if has_loot? && !searched
      parts << 'There might be treasure here.'
    end

    parts.join(' ')
  end

  # ====== Action Handlers ======

  # Search this room for hidden items/traps
  def search!
    return false if searched

    update(searched: true, searched_at: Time.now)
    true
  end

  # Mark room as searched
  def searched?
    searched == true
  end

  # Trigger a trap in this room
  def trigger_trap!
    return 0 if trap_triggered

    update(trap_triggered: true)
    trap_damage || 0
  end

  # Clear a monster from this room
  def clear_monster!
    return false if monster_cleared || monster_type.nil?

    update(monster_cleared: true, cleared: true, cleared_at: Time.now)
    true
  end

  # Check if this room has an uncleared monster
  def has_monster?
    monster_type && !monster_type.empty? && !monster_cleared
  end
  alias monster? has_monster?

  # Check if this room has an active (undisabled) trap
  def has_trap?
    DelveTrap.where(delve_room_id: id, disabled: false).any?
  end
  alias trap? has_trap?

  # Check if room is safe to pass through
  def safe?
    !has_monster? && !has_trap?
  end
end
