# frozen_string_literal: true

# Service for cover line-of-sight blocking mechanics
class CoverLosService
  # Group cover hexes into contiguous blocks
  # Hexes are contiguous if they are neighbors in the hex grid
  #
  # @param cover_hexes [Array<RoomHex>] cover hexes along attack path
  # @return [Array<Array<RoomHex>>] array of blocks (each block is array of hexes)
  def self.group_contiguous_blocks(cover_hexes)
    return [] if cover_hexes.empty?

    blocks = []
    remaining = cover_hexes.dup

    while remaining.any?
      # Start new block with first remaining hex
      current_block = [remaining.shift]

      # Keep adding adjacent hexes to this block
      added = true
      while added
        added = false

        remaining.each do |hex|
          # Check if hex is adjacent to any hex in current block
          if current_block.any? { |block_hex| adjacent?(block_hex, hex) }
            current_block << hex
            remaining.delete(hex)
            added = true
          end
        end
      end

      blocks << current_block
    end

    blocks
  end

  # Check if two hexes are adjacent in hex grid
  #
  # @param hex1 [RoomHex]
  # @param hex2 [RoomHex]
  # @return [Boolean]
  def self.adjacent?(hex1, hex2)
    neighbors = HexGrid.hex_neighbors(hex1.hex_x, hex1.hex_y)
    neighbors.include?([hex2.hex_x, hex2.hex_y])
  end

  # Find the first cover hex that blocks a ranged attack.
  # A cover hex blocks if it's not adjacent to the attacker.
  #
  # @param attacker_pos [Array<Integer, Integer>] [hex_x, hex_y]
  # @param hexes_in_path [Array<RoomHex>] all hexes along attack path
  # @return [RoomHex, nil] the blocking cover hex, or nil
  def self.blocking_cover_hex(attacker_pos:, hexes_in_path:)
    cover_hexes = hexes_in_path.select { |h| h.provides_cover? }
    return nil if cover_hexes.empty?

    attacker_adjacent = HexGrid.hex_neighbors(attacker_pos[0], attacker_pos[1])

    # Return the first cover hex the attacker isn't adjacent to
    cover_hexes.find do |hex|
      !attacker_adjacent.include?([hex.hex_x, hex.hex_y])
    end
  end

  # Check if cover penalty applies to this attack
  # Cover applies if attack path crosses cover block(s) that attacker is not adjacent to
  #
  # @param attacker_pos [Array<Integer, Integer>] [hex_x, hex_y]
  # @param hexes_in_path [Array<RoomHex>] all hexes along attack path
  # @return [Boolean] true if cover penalty applies
  def self.cover_applies?(attacker_pos:, hexes_in_path:)
    # Filter to only cover hexes
    cover_hexes = hexes_in_path.select { |h| h.provides_cover? }
    return false if cover_hexes.empty?

    # Group into contiguous blocks
    blocks = group_contiguous_blocks(cover_hexes)

    # Get attacker's adjacent hexes
    attacker_adjacent = HexGrid.hex_neighbors(attacker_pos[0], attacker_pos[1])

    # Cover applies if ANY block is not adjacent to attacker
    blocks.any? do |block|
      block.none? { |hex| attacker_adjacent.include?([hex.hex_x, hex.hex_y]) }
    end
  end
end
