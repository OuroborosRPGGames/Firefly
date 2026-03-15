# frozen_string_literal: true

require 'set'

# BattleMapConnectivity validates that all traversable hexes on a battle map
# are reachable from a single connected region. Isolated pockets of traversable
# hexes (unreachable from the main area) are converted to walls.
#
# Provides two entry points:
# - ensure_traversable_connectivity(hex_data) for in-memory hex arrays (AI generator)
# - ensure_traversable_connectivity_in_db(room) for persisted RoomHex records (procedural generator)
module BattleMapConnectivity
  # In-memory pass: validates hex_data array before DB persist.
  # Converts isolated traversable hexes to walls.
  # @param hex_data [Array<Hash>] hashes with :x, :y, :hex_type, :traversable
  # @return [Array<Hash>] modified array
  def ensure_traversable_connectivity(hex_data)
    traversable = hex_data.select do |h|
      h.key?(:traversable) ? h[:traversable] : !%w[wall pit off_map].include?(h[:hex_type].to_s)
    end
    return hex_data if traversable.length < 2

    traversable_set = Set.new(traversable.map { |h| [h[:x], h[:y]] })
    seed = find_center_traversable(traversable)
    return hex_data unless seed

    reachable = bfs_reachable(seed, traversable_set)
    isolated = traversable_set - reachable
    return hex_data if isolated.empty?

    warn "[BattleMapConnectivity] Converted #{isolated.size} isolated traversable hexes to walls"

    hex_data.map do |h|
      if isolated.include?([h[:x], h[:y]])
        h.merge(hex_type: 'wall', traversable: false)
      else
        h
      end
    end
  rescue StandardError => e
    warn "[BattleMapConnectivity] ensure_traversable_connectivity failed: #{e.message}"
    hex_data
  end

  # DB pass: validates persisted RoomHex records.
  # Updates isolated traversable hexes to walls in-place.
  # @param room [Room] room whose hexes to validate
  def ensure_traversable_connectivity_in_db(room)
    all_hexes = room.room_hexes_dataset.select(:hex_x, :hex_y, :traversable).all
    traversable = all_hexes.select(&:traversable)
    return if traversable.length < 2

    traversable_set = Set.new(traversable.map { |h| [h.hex_x, h.hex_y] })
    seed = find_center_traversable_db(traversable)
    return unless seed

    reachable = bfs_reachable(seed, traversable_set)
    isolated = traversable_set - reachable
    return if isolated.empty?

    warn "[BattleMapConnectivity] DB: Converted #{isolated.size} isolated hexes to walls (room #{room.id})"

    isolated.each do |hx, hy|
      room.room_hexes_dataset.where(hex_x: hx, hex_y: hy).update(
        hex_type: 'wall', traversable: false
      )
    end
  rescue StandardError => e
    warn "[BattleMapConnectivity] ensure_traversable_connectivity_in_db failed: #{e.message}"
  end

  # In-memory pass: removes non-traversable border hexes that are outside the
  # 1-hex neighbor buffer of any traversable hex, then remaps coordinates to (0,0).
  # @param hex_data [Array<Hash>] hashes with :x, :y, :hex_type, :traversable
  # @return [Array<Hash>] cropped and remapped array
  def crop_non_traversable_border(hex_data)
    return hex_data if hex_data.empty?

    traversable = hex_data.select { |h| h[:traversable] }
    return hex_data if traversable.empty?

    # Keep set = traversable + 1-hex neighbor buffer
    keep_coords = Set.new
    traversable.each do |h|
      keep_coords.add([h[:x], h[:y]])
      HexGrid.hex_neighbors(h[:x], h[:y]).each { |nx, ny| keep_coords.add([nx, ny]) }
    end

    cropped = hex_data.select { |h| keep_coords.include?([h[:x], h[:y]]) }
    return hex_data if cropped.size == hex_data.size

    warn "[BattleMapConnectivity] Cropped #{hex_data.size - cropped.size} border hexes"

    # Remap to (0,0) using parity-safe shift to preserve hex grid validity
    min_x = cropped.map { |h| h[:x] }.min
    min_y = cropped.map { |h| h[:y] }.min
    return cropped if min_x == 0 && min_y == 0

    min_x, min_y = HexGrid.parity_safe_origin(min_x, min_y)
    cropped.map { |h| h.merge(x: h[:x] - min_x, y: h[:y] - min_y) }
  rescue StandardError => e
    warn "[BattleMapConnectivity] crop_non_traversable_border failed: #{e.message}"
    hex_data
  end

  # DB pass: removes non-traversable border hexes from persisted RoomHex records,
  # remaps remaining coordinates to (0,0), and updates arena dimensions on active fights.
  # @param room [Room] room whose hexes to crop
  def crop_non_traversable_border_in_db(room)
    all_hexes = room.room_hexes_dataset.select(:id, :hex_x, :hex_y, :traversable).all
    return if all_hexes.size < 2

    traversable = all_hexes.select(&:traversable)
    return if traversable.empty?

    # Keep set = traversable + 1-hex neighbor buffer
    keep_coords = Set.new
    traversable.each do |h|
      keep_coords.add([h.hex_x, h.hex_y])
      HexGrid.hex_neighbors(h.hex_x, h.hex_y).each { |nx, ny| keep_coords.add([nx, ny]) }
    end

    to_delete = all_hexes.reject { |h| keep_coords.include?([h.hex_x, h.hex_y]) }
    return if to_delete.empty?

    warn "[BattleMapConnectivity] DB: Cropping #{to_delete.size} border hexes (room #{room.id})"

    # Delete border hexes
    delete_ids = to_delete.map(&:id)
    room.room_hexes_dataset.where(id: delete_ids).delete

    # Calculate coordinate shift
    remaining = room.room_hexes_dataset.select(:hex_x, :hex_y).all
    return if remaining.empty?

    min_x = remaining.map(&:hex_x).min
    min_y = remaining.map(&:hex_y).min

    if min_x != 0 || min_y != 0
      # Use parity-safe shift to preserve hex grid coordinate validity
      min_x, min_y = HexGrid.parity_safe_origin(min_x, min_y)

      # Shift all coordinates - delete and re-insert to avoid unique constraint conflicts
      full_records = room.room_hexes_dataset.all
      room.room_hexes_dataset.delete

      now = Time.now
      shifted = full_records.map do |h|
        vals = h.values.dup
        vals.delete(:id)
        vals[:hex_x] -= min_x
        vals[:hex_y] -= min_y
        vals[:updated_at] = now
        vals
      end

      RoomHex.multi_insert(shifted) if shifted.any?
    end

    # Update arena dimensions on active fights
    update_arena_dimensions_for_room(room)
  rescue StandardError => e
    warn "[BattleMapConnectivity] crop_non_traversable_border_in_db failed: #{e.message}"
  end

  # Calculate arena dimensions from hex data array.
  # Inverse of HexGrid formulas:
  #   hex_max_x = arena_width - 1
  #   hex_max_y = (arena_height - 1) * 4 + 2
  # So: arena_width = max_x + 1, arena_height = (max_y - 2) / 4 + 1
  # @param hex_data [Array<Hash>] hashes with :x, :y
  # @return [Array<Integer>] [arena_width, arena_height]
  def arena_dimensions_from_hex_data(hex_data)
    return [1, 1] if hex_data.empty?

    max_x = hex_data.map { |h| h[:x] }.compact.max
    max_y = hex_data.map { |h| h[:y] }.compact.max
    return [1, 1] unless max_x && max_y

    arena_width = max_x + 1
    # Ceiling division: hex_max_y = (h-1)*4+2, so h = ceil((max_y-2)/4) + 1
    arena_height = max_y >= 2 ? (max_y + 1) / 4 + 1 : 1
    [arena_width, [arena_height, 1].max]
  end

  private

  def bfs_reachable(seed, traversable_set)
    reachable = Set.new
    queue = [seed]
    while (current = queue.shift)
      next if reachable.include?(current)

      reachable.add(current)
      HexGrid.hex_neighbors(current[0], current[1]).each do |nx, ny|
        queue << [nx, ny] if traversable_set.include?([nx, ny]) && !reachable.include?([nx, ny])
      end
    end
    reachable
  end

  def find_center_traversable(traversable)
    xs = traversable.map { |h| h[:x] }
    ys = traversable.map { |h| h[:y] }
    cx, cy = HexGrid.to_hex_coords((xs.min + xs.max) / 2, (ys.min + ys.max) / 2)
    nearest = traversable.min_by { |h| HexGrid.hex_distance(h[:x], h[:y], cx, cy) }
    nearest ? [nearest[:x], nearest[:y]] : nil
  end

  def find_center_traversable_db(traversable)
    xs = traversable.map(&:hex_x)
    ys = traversable.map(&:hex_y)
    cx, cy = HexGrid.to_hex_coords((xs.min + xs.max) / 2, (ys.min + ys.max) / 2)
    nearest = traversable.min_by { |h| HexGrid.hex_distance(h.hex_x, h.hex_y, cx, cy) }
    nearest ? [nearest.hex_x, nearest.hex_y] : nil
  end

  def update_arena_dimensions_for_room(room)
    remaining = room.room_hexes_dataset.select(:hex_x, :hex_y).all
    return if remaining.empty?

    max_x = remaining.map(&:hex_x).max
    max_y = remaining.map(&:hex_y).max
    new_w = max_x + 1
    new_h = max_y >= 2 ? (max_y - 2) / 4 + 1 : 1
    new_h = [new_h, 1].max

    Fight.where(room_id: room.id).exclude(status: 'ended').update(
      arena_width: new_w, arena_height: new_h
    )
  rescue StandardError => e
    warn "[BattleMapConnectivity] update_arena_dimensions_for_room failed: #{e.message}"
  end
end
