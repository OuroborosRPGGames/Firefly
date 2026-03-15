# frozen_string_literal: true

require 'spec_helper'
require 'vips'
require 'tmpdir'

RSpec.describe FireMaskHexSyncService do
  def write_white_mask(path, width: 96, height: 96)
    white = (Vips::Image.black(width, height) + 255).cast(:uchar)
    white.pngsave(path)
  end

  def write_focused_mask(path, room:, target_coord:, width: 96, height: 96)
    base = Vips::Image.black(width, height).cast(:uchar)
    coords = HexGrid.hex_coords_for_records(room, hexes: room.room_hexes_dataset.all)
    service = described_class.new(path)
    lookup, _hex_size = service.send(:build_coord_lookup, coords, width, height)
    px = lookup.fetch(target_coord)[:px]
    py = lookup.fetch(target_coord)[:py]

    patch = (Vips::Image.black(9, 9) + 255).cast(:uchar)
    x = [[px - 4, 0].max, width - 9].min
    y = [[py - 4, 0].max, height - 9].min
    focused = base.insert(patch, x, y)
    focused.pngsave(path)
  end

  describe '.sync_room!' do
    let(:room) { create(:room, min_x: 0, max_x: 20, min_y: 0, max_y: 20) }

    it 'marks overlapping room hexes as fire hazards' do
      hex = RoomHex.create(
        room_id: room.id,
        hex_x: 0,
        hex_y: 0,
        hex_type: 'normal',
        traversable: true,
        danger_level: 0
      )

      Dir.mktmpdir do |dir|
        mask_path = File.join(dir, 'fire_mask.png')
        write_white_mask(mask_path)

        result = described_class.sync_room!(room: room, mask_path: mask_path)

        expect(result[:marked_hexes]).to be >= 1
        expect(result[:updated_hexes]).to be >= 1

        hex.refresh
        expect(hex.hex_type).to eq('fire')
        expect(hex.hazard_type).to eq('fire')
        expect(hex.danger_level.to_i).to be >= 3
      end
    end

    it 'preserves structural wall hex type while adding fire hazard metadata' do
      hex = RoomHex.create(
        room_id: room.id,
        hex_x: 0,
        hex_y: 0,
        hex_type: 'wall',
        traversable: false,
        danger_level: 0
      )

      Dir.mktmpdir do |dir|
        mask_path = File.join(dir, 'fire_mask.png')
        write_white_mask(mask_path)

        described_class.sync_room!(room: room, mask_path: mask_path)

        hex.refresh
        expect(hex.hex_type).to eq('wall')
        expect(hex.hazard_type).to eq('fire')
        expect(hex.danger_level.to_i).to be >= 3
      end
    end

    it 'punches out adjacent cover when a fire hex would be inaccessible' do
      fire_hex = RoomHex.create(room_id: room.id, hex_x: 1, hex_y: 2, hex_type: 'normal', traversable: true, danger_level: 0)
      blocked_cover = RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'cover', traversable: false, has_cover: true, cover_object: 'crate', danger_level: 0)
      RoomHex.create(room_id: room.id, hex_x: 2, hex_y: 0, hex_type: 'wall', traversable: false, danger_level: 0)
      RoomHex.create(room_id: room.id, hex_x: 2, hex_y: 4, hex_type: 'wall', traversable: false, danger_level: 0)
      RoomHex.create(room_id: room.id, hex_x: 1, hex_y: 6, hex_type: 'wall', traversable: false, danger_level: 0)
      RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 4, hex_type: 'wall', traversable: false, danger_level: 0)

      Dir.mktmpdir do |dir|
        mask_path = File.join(dir, 'fire_mask.png')
        write_focused_mask(mask_path, room: room, target_coord: [1, 2])

        result = described_class.sync_room!(room: room, mask_path: mask_path)
        expect(result[:marked_hexes]).to be >= 1
        expect(result[:punched_out_hexes]).to be >= 1

        fire_hex.refresh
        blocked_cover.refresh

        expect(fire_hex.hex_type).to eq('fire')
        expect(blocked_cover.hex_type).to eq('normal')
        expect(blocked_cover.traversable).to eq(true)
        expect(blocked_cover.difficult_terrain).to eq(true)
        expect(blocked_cover.has_cover).to eq(false)
      end
    end
  end

  describe '.sync_template!' do
    it 'updates template hex_data to include fire hazard classification' do
      template = BattleMapTemplate.create(
        category: 'delve',
        shape_key: 'small_chamber',
        variant: 99,
        width_feet: 2.0,
        height_feet: 2.0,
        hex_data: Sequel.pg_jsonb_wrap([{ 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal', 'traversable' => true }]),
        description_hint: 'sync test'
      )

      Dir.mktmpdir do |dir|
        mask_path = File.join(dir, 'fire_mask.png')
        write_white_mask(mask_path)

        result = described_class.sync_template!(template: template, mask_path: mask_path)
        expect(result[:marked_hexes]).to be >= 1
        expect(result[:updated_hexes]).to be >= 1
      end

      template.refresh
      data = template.hex_data.to_a
      fire_hex = data.find { |h| h['hex_x'].to_i == 0 && h['hex_y'].to_i == 0 }
      expect(fire_hex).not_to be_nil
      expect(fire_hex['hex_type']).to eq('fire')
      expect(fire_hex['hazard_type']).to eq('fire')
      expect(fire_hex['danger_level'].to_i).to be >= 3
    end
  end
end
