# frozen_string_literal: true

module HexGrid
  # Combat hex size: each hex = 2 feet (finer grid for AI classification)
  HEX_SIZE_FEET = 2

  # Maximum aspect ratio for arena dimensions (3:1)
  # Prevents impractically long/narrow battlemaps for streets and corridors
  MAX_ARENA_ASPECT_RATIO = 3.0

  # Arena dimension below which no compression is applied.
  # Rooms yielding up to this many hexes per axis keep 1:1 hex-per-2ft mapping.
  ARENA_COMPRESS_THRESHOLD = 30

  # Maximum arena size in hexes per side after compression.
  # A 180ft room (90 natural hexes) compresses to (90+30)/2 = 60.
  MAX_ARENA_DIMENSION = 60

  # Convert feet coordinates to hex coordinates
  # @param feet_x [Float] x position in feet
  # @param feet_y [Float] y position in feet
  # @param room_min_x [Float] room's min_x bound (default 0)
  # @param room_min_y [Float] room's min_y bound (default 0)
  # @return [Array<Integer, Integer>] valid hex_x, hex_y
  def self.feet_to_hex(feet_x, feet_y, room_min_x = 0, room_min_y = 0)
    relative_x = feet_x - room_min_x
    relative_y = feet_y - room_min_y

    raw_hex_x = (relative_x / HEX_SIZE_FEET).round
    raw_hex_y = (relative_y / HEX_SIZE_FEET).round

    to_hex_coords(raw_hex_x, raw_hex_y)
  end

  # Convert hex coordinates back to feet (center of hex)
  # @param hex_x [Integer] hex x position
  # @param hex_y [Integer] hex y position
  # @param room_min_x [Float] room's min_x bound (default 0)
  # @param room_min_y [Float] room's min_y bound (default 0)
  # @return [Array<Float, Float>] feet_x, feet_y
  def self.hex_to_feet(hex_x, hex_y, room_min_x = 0, room_min_y = 0)
    feet_x = (hex_x * HEX_SIZE_FEET) + room_min_x
    feet_y = (hex_y * HEX_SIZE_FEET) + room_min_y
    [feet_x.to_f, feet_y.to_f]
  end

  # Calculate arena dimensions from room size in feet
  # @param room_width_feet [Float] room width (max_x - min_x)
  # @param room_height_feet [Float] room height (max_y - min_y)
  # @return [Array<Integer, Integer>] arena_width, arena_height in hexes
  def self.arena_dimensions_from_feet(room_width_feet, room_height_feet)
    arena_width = [(room_width_feet.to_f / HEX_SIZE_FEET).ceil, 1].max
    arena_height = [(room_height_feet.to_f / HEX_SIZE_FEET).ceil, 1].max

    # Compress large arenas: dimensions above the threshold are averaged
    # with the threshold so big rooms get more hexes than before (old hard
    # cap was 30) but don't grow 1:1 with room feet.
    # E.g. 90 natural hexes → (90 + 30) / 2 = 60 hex grid dimension.
    arena_width = compress_dimension(arena_width)
    arena_height = compress_dimension(arena_height)

    # Enforce maximum aspect ratio (3:1) to prevent impractically narrow battlemaps
    if arena_width > arena_height * MAX_ARENA_ASPECT_RATIO
      arena_width = (arena_height * MAX_ARENA_ASPECT_RATIO).to_i
    elsif arena_height > arena_width * MAX_ARENA_ASPECT_RATIO
      arena_height = (arena_width * MAX_ARENA_ASPECT_RATIO).to_i
    end

    [arena_width, arena_height]
  end

  # Compress a single arena dimension.
  # Dimensions at or below ARENA_COMPRESS_THRESHOLD pass through unchanged.
  # Larger dimensions are averaged with the threshold, then hard-capped at
  # MAX_ARENA_DIMENSION.
  def self.compress_dimension(natural)
    return natural if natural <= ARENA_COMPRESS_THRESHOLD

    [((natural + ARENA_COMPRESS_THRESHOLD) / 2.0).round, MAX_ARENA_DIMENSION].min
  end

  # Check if given x/y coordinates are valid hex coordinates
  # Y coordinates must be even numbers
  # For even Y coordinates (0, 2, 4, ...), X coordinates must be even  
  # For odd Y coordinates (this shouldn't happen since Y must be even), X coordinates must be odd
  # Wait - let me re-read the requirements...
  # 
  # Actually, the requirements state:
  # - Y coords are valid if they are even numbers
  # - X coords should be even or odd based on Y coord
  # - y coord 0: x should all be even
  # - y coord 2: x should all be odd  
  # - y coord 4: x should all be even
  # So the pattern is: y=0,4,8,... (divisible by 4) -> x even; y=2,6,10,... (2+4n) -> x odd
  
  def self.valid_hex_coords?(x, y)
    # Y must be even
    return false unless y.even?
    
    # Determine if X should be even or odd based on Y
    if (y / 2).even?
      # y = 0, 4, 8, 12... -> x should be even
      x.even?
    else
      # y = 2, 6, 10, 14... -> x should be odd
      x.odd?
    end
  end
  
  # Adjust a shift origin (min_x, min_y) so that subtracting it from valid hex
  # coordinates produces valid hex coordinates. The shift is "parity-safe" iff
  # (min_x, min_y) is itself a valid hex coordinate.
  # Reduces min_x by 1 when necessary (always safe: just shifts one less).
  def self.parity_safe_origin(min_x, min_y)
    return [min_x, min_y] if valid_hex_coords?(min_x, min_y)

    # Adjust min_x to match the parity expected for this Y row
    if (min_y / 2).even?
      # Row expects even X
      [min_x.even? ? min_x : min_x - 1, min_y]
    else
      # Row expects odd X
      [min_x.odd? ? min_x : min_x - 1, min_y]
    end
  end

  # Convert any x/y coordinate to the closest valid hex coordinates
  def self.to_hex_coords(x, y)
    # First, snap Y to the nearest even number
    hex_y = (y.to_f / 2).round * 2
    
    # Determine if X should be even or odd for this Y
    if (hex_y / 2).even?
      # Y = 0, 4, 8, 12... -> X should be even
      hex_x = (x.to_f / 2).round * 2
    else
      # Y = 2, 6, 10, 14... -> X should be odd
      # For odd numbers, we want the closest odd number
      hex_x = ((x.to_f - 1) / 2).round * 2 + 1
    end
    
    [hex_x, hex_y]
  end
  
  # Generate valid hex coordinates for a room given its feet bounds.
  # Converts the room's physical dimensions to an arena grid of the appropriate
  # size (based on HEX_SIZE_FEET), then generates proper offset hex coordinates
  # starting from (0, 0). This is the standard way to get hex coordinates for
  # battle maps - use this instead of hex_coords_in_bounds with raw feet values.
  #
  # @param room_min_x [Float] room min_x in feet
  # @param room_min_y [Float] room min_y in feet
  # @param room_max_x [Float] room max_x in feet
  # @param room_max_y [Float] room max_y in feet
  # @return [Array<Array<Integer>>] array of [hex_x, hex_y] coordinate pairs
  def self.hex_coords_for_room(room_min_x, room_min_y, room_max_x, room_max_y)
    room_width = room_max_x - room_min_x
    room_height = room_max_y - room_min_y
    arena_w, arena_h = arena_dimensions_from_feet(room_width, room_height)

    # Convert arena dimensions to offset coordinate bounds.
    # arena_w columns → max hex x = arena_w - 1
    # arena_h visual rows → max hex y includes both even and odd Y-values
    #   for the last visual row, so (arena_h - 1) * 4 + 2
    hex_max_x = [arena_w - 1, 0].max
    hex_max_y = [(arena_h - 1) * 4 + 2, 0].max

    hex_coords_in_bounds(0, 0, hex_max_x, hex_max_y)
  end

  # Get all valid hex coordinates within a given rectangular bounds
  def self.hex_coords_in_bounds(min_x, min_y, max_x, max_y)
    coords = []
    
    # Start with the minimum even Y
    start_y = (min_y.to_f / 2).ceil * 2
    
    y = start_y
    while y <= max_y
      if (y / 2).even?
        # Y = 0, 4, 8... -> X should be even
        start_x = (min_x.to_f / 2).ceil * 2
        x = start_x
        while x <= max_x
          coords << [x, y]
          x += 2
        end
      else
        # Y = 2, 6, 10... -> X should be odd
        start_x = ((min_x.to_f - 1) / 2).ceil * 2 + 1
        x = start_x
        while x <= max_x
          coords << [x, y]
          x += 2
        end
      end
      y += 2
    end
    
    coords
  end
  
  # Calculate distance between two hex coordinates
  # In this offset system, diagonal moves cover ±1 in x and ±2 in y,
  # while north/south moves cover 0 in x and ±4 in y.
  # Distance = diagonal steps + remaining N/S steps.
  def self.hex_distance(x1, y1, x2, y2)
    dx = (x2 - x1).abs
    dy = (y2 - y1).abs

    if dy <= 2 * dx
      # Diagonal moves cover all y-distance (zigzag absorbs excess)
      dx
    else
      # dx diagonal steps cover 2*dx in y, then N/S steps (each covers 4 in y)
      dx + (dy - 2 * dx) / 4
    end
  end
  
  # Get the neighbors of a hex coordinate
  # Returns neighbors in order: N, NE, SE, S, SW, NW (clockwise from north)
  # All 6 neighbor offsets are identical regardless of even/odd row.
  def self.hex_neighbors(x, y)
    return [] unless valid_hex_coords?(x, y)

    neighbors = [
      [x,     y + 4],  # N  (directly north, same column)
      [x + 1, y + 2],  # NE (north-east, adjacent column)
      [x + 1, y - 2],  # SE (south-east, adjacent column)
      [x,     y - 4],  # S  (directly south, same column)
      [x - 1, y - 2],  # SW (south-west, adjacent column)
      [x - 1, y + 2]   # NW (north-west, adjacent column)
    ]

    # Filter to only valid hex coordinates
    neighbors.select { |nx, ny| valid_hex_coords?(nx, ny) }
  end
  
  # Get a specific neighbor by direction
  def self.hex_neighbor_by_direction(x, y, direction)
    return nil unless valid_hex_coords?(x, y)

    direction_index = {
      'N'  => 0, 'n'  => 0, :n  => 0,
      'NE' => 1, 'ne' => 1, :ne => 1,
      'SE' => 2, 'se' => 2, :se => 2,
      'S'  => 3, 's'  => 3, :s  => 3,
      'SW' => 4, 'sw' => 4, :sw => 4,
      'NW' => 5, 'nw' => 5, :nw => 5
    }[direction]

    return nil unless direction_index

    neighbors = hex_neighbors(x, y)
    neighbors[direction_index]
  end

  # Get all valid directions from a hex coordinate
  def self.available_directions(x, y)
    return [] unless valid_hex_coords?(x, y)

    neighbors = hex_neighbors(x, y)
    directions = ['N', 'NE', 'SE', 'S', 'SW', 'NW']

    # Return only directions that have valid neighbors
    directions.first(neighbors.length)
  end

  # Get valid hex coordinates based on existing hex records for a room.
  # Uses the actual record extent to avoid phantom wall rows/columns from
  # arena_dimensions_from_feet overshooting the data.
  #
  # Falls back to room feet bounds (or explicit arena dimensions) when
  # no hex records exist.
  #
  # @param room [Room] the room to get hex coordinates for
  # @param hexes [Array, nil] pre-loaded hex records (avoids DB query if provided)
  # @param fallback_arena_width [Integer, nil] arena width if no records (optional)
  # @param fallback_arena_height [Integer, nil] arena height if no records (optional)
  # @return [Array<Array<Integer>>] array of [hex_x, hex_y] coordinate pairs
  def self.hex_coords_for_records(room, hexes: nil, fallback_arena_width: nil, fallback_arena_height: nil)
    hexes = RoomHex.where(room_id: room.id).all if hexes.nil?
    if hexes.any?
      xs = hexes.map(&:hex_x)
      ys = hexes.map(&:hex_y)
      hex_coords_in_bounds(xs.min, ys.min, xs.max, ys.max)
    elsif fallback_arena_width && fallback_arena_height
      hex_max_x = [fallback_arena_width - 1, 0].max
      hex_max_y = [(fallback_arena_height - 1) * 4 + 2, 0].max
      hex_coords_in_bounds(0, 0, hex_max_x, hex_max_y)
    elsif room.respond_to?(:min_x) && room.min_x && room.max_x
      hex_coords_for_room(room.min_x, room.min_y, room.max_x, room.max_y)
    else
      []
    end
  end

  # Clamp coordinates to valid hex positions within arena bounds.
  # Shared implementation used by all combat services.
  # @param hex_x [Integer] raw x coordinate
  # @param hex_y [Integer] raw y coordinate
  # @param arena_width [Integer] arena width in columns
  # @param arena_height [Integer] arena height in visual rows
  # @return [Array<Integer, Integer>] valid [hex_x, hex_y] within bounds
  def self.clamp_to_arena(hex_x, hex_y, arena_width, arena_height)
    max_x = [arena_width - 1, 0].max
    max_y = [(arena_height - 1) * 4 + 2, 0].max
    hex_x, hex_y = to_hex_coords(hex_x, hex_y)
    hex_x = hex_x.clamp(0, max_x)
    hex_y = hex_y.clamp(0, max_y)
    hex_x, hex_y = to_hex_coords(hex_x, hex_y)
    hex_x -= 2 if hex_x > max_x
    hex_y -= 2 if hex_y > max_y
    [hex_x, hex_y]
  end
end