# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CoverLosService do
  let(:room) { create(:room) }

  describe '.group_contiguous_blocks' do
    it 'groups adjacent cover hexes into single block' do
      # (0,0) ↔ (1,2) ↔ (2,0) form a contiguous chain of neighbors
      hex1 = RoomHex.create(room: room, hex_x: 0, hex_y: 0, has_cover: true, danger_level: 0)
      hex2 = RoomHex.create(room: room, hex_x: 1, hex_y: 2, has_cover: true, danger_level: 0)
      hex3 = RoomHex.create(room: room, hex_x: 2, hex_y: 0, has_cover: true, danger_level: 0)

      blocks = CoverLosService.group_contiguous_blocks([hex1, hex2, hex3])

      expect(blocks.length).to eq(1)
      expect(blocks[0].length).to eq(3)
    end

    it 'separates non-adjacent cover into multiple blocks' do
      # Group 1: (0,0) ↔ (1,2) - neighbors
      hex1 = RoomHex.create(room: room, hex_x: 0, hex_y: 0, has_cover: true, danger_level: 0)
      hex2 = RoomHex.create(room: room, hex_x: 1, hex_y: 2, has_cover: true, danger_level: 0)
      # Group 2: (8,0) ↔ (9,2) - neighbors, far from group 1
      hex3 = RoomHex.create(room: room, hex_x: 8, hex_y: 0, has_cover: true, danger_level: 0)
      hex4 = RoomHex.create(room: room, hex_x: 9, hex_y: 2, has_cover: true, danger_level: 0)

      blocks = CoverLosService.group_contiguous_blocks([hex1, hex2, hex3, hex4])

      expect(blocks.length).to eq(2)
      expect(blocks[0].length).to eq(2) # hex1, hex2
      expect(blocks[1].length).to eq(2) # hex3, hex4
    end

    it 'handles single hex as single block' do
      hex1 = RoomHex.create(room: room, hex_x: 0, hex_y: 0, has_cover: true, danger_level: 0)

      blocks = CoverLosService.group_contiguous_blocks([hex1])

      expect(blocks.length).to eq(1)
      expect(blocks[0].length).to eq(1)
    end

    it 'handles empty array' do
      blocks = CoverLosService.group_contiguous_blocks([])

      expect(blocks).to eq([])
    end
  end

  describe '.cover_applies?' do
    it 'returns false if no cover hexes in path' do
      result = CoverLosService.cover_applies?(
        attacker_pos: [0, 0],
        hexes_in_path: []
      )
      expect(result).to be false
    end

    it 'returns false if attacker adjacent to all cover blocks' do
      # Attacker at (0,0), cover at (1,2) - adjacent (NE neighbor)
      cover = RoomHex.create(room: room, hex_x: 1, hex_y: 2, has_cover: true, danger_level: 0)

      result = CoverLosService.cover_applies?(
        attacker_pos: [0, 0],
        hexes_in_path: [cover]
      )
      expect(result).to be false
    end

    it 'returns true if attacker not adjacent to cover block' do
      # Attacker at (0,0), cover at (6,0) - not adjacent (distance 6)
      cover = RoomHex.create(room: room, hex_x: 6, hex_y: 0, has_cover: true, danger_level: 0)

      result = CoverLosService.cover_applies?(
        attacker_pos: [0, 0],
        hexes_in_path: [cover]
      )
      expect(result).to be true
    end

    it 'handles multiple blocks - applies if any block not adjacent' do
      # Attacker at (0,0)
      # Block 1: (1,2) - adjacent to attacker (NE neighbor)
      # Block 2: (8,0), (9,2) - not adjacent to attacker
      cover1 = RoomHex.create(room: room, hex_x: 1, hex_y: 2, has_cover: true, danger_level: 0)
      cover2 = RoomHex.create(room: room, hex_x: 8, hex_y: 0, has_cover: true, danger_level: 0)
      cover3 = RoomHex.create(room: room, hex_x: 9, hex_y: 2, has_cover: true, danger_level: 0)

      result = CoverLosService.cover_applies?(
        attacker_pos: [0, 0],
        hexes_in_path: [cover1, cover2, cover3]
      )
      expect(result).to be true
    end
  end
end
