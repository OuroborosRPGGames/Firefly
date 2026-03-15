# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe WallMaskService do
  let(:room) do
    double('Room',
           id: 1,
           min_x: 0.0, max_x: 20.0,
           min_y: 0.0, max_y: 20.0,
           battle_map_wall_mask_url: '/uploads/test_mask.png',
           battle_map_wall_mask_width: 100,
           battle_map_wall_mask_height: 100)
  end

  let(:room_no_mask) do
    double('Room',
           id: 2,
           battle_map_wall_mask_url: nil)
  end

  let(:room_empty_mask) do
    double('Room',
           id: 3,
           battle_map_wall_mask_url: '')
  end

  describe '.for_room' do
    it 'returns nil when room has no wall mask URL' do
      expect(described_class.for_room(room_no_mask)).to be_nil
    end

    it 'returns nil when room has empty wall mask URL' do
      expect(described_class.for_room(room_empty_mask)).to be_nil
    end

    it 'returns a service instance when room has a mask URL' do
      expect(described_class.for_room(room)).to be_a(described_class)
    end

    it 'returns nil for rooms that do not respond to battle_map_wall_mask_url' do
      bare_room = double('Room')
      expect(described_class.for_room(bare_room)).to be_nil
    end
  end

  describe '#hex_to_pixel' do
    subject(:service) { described_class.new(room) }

    it 'maps origin hex to bottom-left area (Y-flipped: north at top)' do
      px, py = service.hex_to_pixel(0, 0)
      # hex(0,0) is the south-west corner → low pixel X, high pixel Y
      expect(px).to be_between(0, 50)
      expect(py).to be_between(50, 100)
    end

    it 'maps a hex to a pixel within mask bounds' do
      px, py = service.hex_to_pixel(3, 4)
      expect(px).to be_between(0, 100)
      expect(py).to be_between(0, 100)
    end

    it 'higher hex_x maps to higher pixel_x' do
      px1, _  = service.hex_to_pixel(0, 0)
      px2, _  = service.hex_to_pixel(3, 0)
      expect(px2).to be > px1
    end

    it 'higher hex_y maps to lower pixel_y (Y-flipped)' do
      _, py1 = service.hex_to_pixel(0, 0)
      _, py2 = service.hex_to_pixel(0, 8)
      expect(py2).to be < py1
    end
  end

  describe '#feet_to_pixel and #pixel_to_feet' do
    subject(:service) { described_class.new(room) }

    it 'pixel_to_feet is inverse of feet_to_pixel (approximate)' do
      fx, fy = 10.0, 10.0
      px, py = service.feet_to_pixel(fx, fy)
      rx, ry = service.pixel_to_feet(px, py)
      expect(rx).to be_within(1.0).of(fx)
      expect(ry).to be_within(1.0).of(fy)
    end
  end

  describe '#ray_los_clear?' do
    subject(:service) { described_class.new(room) }

    context 'when mask cannot be loaded (file not found)' do
      it 'returns true (fail open)' do
        # File does not exist on disk — service gracefully falls back
        result = service.ray_los_clear?(0, 0, 50, 50)
        expect(result).to be true
      end

      it 'does not accept a door_open_fn keyword argument (signature changed)' do
        # Doors are always transparent; no door_open_fn parameter exists
        expect { service.ray_los_clear?(0, 0, 50, 50) }.not_to raise_error
      end
    end
  end

  describe '#compute_passable_edges' do
    subject(:service) { described_class.new(room) }

    context 'when mask cannot be loaded' do
      it 'returns 63 (all edges passable) as fallback' do
        result = service.compute_passable_edges(0, 0)
        expect(result).to eq(63)
      end
    end
  end

  describe 'HEX_OFFSETS constant' do
    it 'has 6 entries matching direction order N,NE,SE,S,SW,NW' do
      expect(described_class::HEX_OFFSETS.length).to eq(6)
    end

    it 'N offset is [0, 4]' do
      expect(described_class::HEX_OFFSETS[0]).to eq([0, 4])
    end

    it 'S offset is [0, -4]' do
      expect(described_class::HEX_OFFSETS[3]).to eq([0, -4])
    end
  end

  describe 'graceful fallback on image load failure' do
    subject(:service) { described_class.new(room) }

    it 'pixel_type returns :floor when image unavailable' do
      # No file exists, so image load fails silently
      result = service.pixel_type(0, 0)
      expect(result).to eq(described_class::FLOOR)
    end

    it 'wall_pixel? returns false when image unavailable' do
      expect(service.wall_pixel?(0, 0)).to be false
    end
  end

  describe '#pixel_type against a real mask PNG' do
    let(:room_with_mask) do
      create(:room, min_x: 0, max_x: 20, min_y: 0, max_y: 20,
             battle_map_wall_mask_url: nil,
             battle_map_wall_mask_width: nil,
             battle_map_wall_mask_height: nil)
    end

    around do |example|
      # Disable vips operation cache so re-reads of the same path pick up changes
      original_cache_max = Vips.cache_max
      Vips.cache_set_max(0)
      Dir.chdir(Dir.mktmpdir) do
        FileUtils.mkdir_p('public/uploads/battle_maps')
        example.run
      end
    ensure
      Vips.cache_set_max(original_cache_max)
    end

    before do
      # Paint the full image as wall so every pixel is red
      WallMaskPainterService.new(room_with_mask).paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      room_with_mask.refresh
    end

    subject(:mask_svc) { described_class.new(room_with_mask) }

    it 'classifies center pixel as :wall (red)' do
      w = room_with_mask.battle_map_wall_mask_width
      h = room_with_mask.battle_map_wall_mask_height
      expect(mask_svc.pixel_type(w / 2, h / 2)).to eq(described_class::WALL)
    end

    it 'wall_pixel? returns true for center pixel' do
      w = room_with_mask.battle_map_wall_mask_width
      h = room_with_mask.battle_map_wall_mask_height
      expect(mask_svc.wall_pixel?(w / 2, h / 2)).to be true
    end

    it 'classifies door pixels correctly after painting door region' do
      # Overwrite with door (green) in top-left quadrant
      WallMaskPainterService.new(room_with_mask).paint_rect(0.0, 0.0, 0.5, 0.5, 'door')
      room_with_mask.refresh
      svc2 = described_class.new(room_with_mask)
      w = room_with_mask.battle_map_wall_mask_width
      h = room_with_mask.battle_map_wall_mask_height
      expect(svc2.pixel_type(w / 4, h / 4)).to eq(described_class::DOOR)
    end
  end
end
