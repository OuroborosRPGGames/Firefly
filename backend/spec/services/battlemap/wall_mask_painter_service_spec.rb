# frozen_string_literal: true

require 'spec_helper'
require 'vips'
require 'fileutils'
require 'tmpdir'

RSpec.describe WallMaskPainterService do
  let(:room) do
    create(:room,
           min_x: 0, max_x: 100, min_y: 0, max_y: 100,
           battle_map_wall_mask_url: nil,
           battle_map_wall_mask_width: nil,
           battle_map_wall_mask_height: nil)
  end

  subject(:service) { described_class.new(room) }

  # Work in a tmp dir so file I/O doesn't pollute the test environment
  around do |example|
    Dir.chdir(Dir.mktmpdir) do
      FileUtils.mkdir_p('public/uploads/battle_maps')
      example.run
    end
  end

  describe '#paint_rect (normalized fracs 0.0–1.0)' do
    it 'creates a mask PNG when none exists' do
      result = service.paint_rect(0.1, 0.1, 0.5, 0.5, 'wall')
      expect(result[:success]).to be true
      expect(result[:mask_url]).to include('wall_mask')
      expect(File.exist?('public' + result[:mask_url])).to be true
    end

    it 'paints wall pixels red' do
      result = service.paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      img = Vips::Image.new_from_file('public' + result[:mask_url])
      pixel = img.getpoint(img.width / 2, img.height / 2)
      expect(pixel[0]).to eq(255)
      expect(pixel[1]).to eq(0)
      expect(pixel[2]).to eq(0)
    end

    it 'paints door pixels green' do
      result = service.paint_rect(0.0, 0.0, 1.0, 1.0, 'door')
      img = Vips::Image.new_from_file('public' + result[:mask_url])
      pixel = img.getpoint(img.width / 2, img.height / 2)
      expect(pixel[0]).to eq(0)
      expect(pixel[1]).to eq(255)
      expect(pixel[2]).to eq(0)
    end

    it 'paints window pixels blue' do
      result = service.paint_rect(0.0, 0.0, 1.0, 1.0, 'window')
      img = Vips::Image.new_from_file('public' + result[:mask_url])
      pixel = img.getpoint(img.width / 2, img.height / 2)
      expect(pixel[0]).to eq(0)
      expect(pixel[1]).to eq(0)
      expect(pixel[2]).to eq(255)
    end

    it 'preserves pixels outside the painted rect' do
      # Fill all red first
      service.paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      room.refresh
      # Paint a door in the bottom-right corner only
      service2 = described_class.new(room)
      result2 = service2.paint_rect(0.9, 0.9, 1.0, 1.0, 'door')
      img = Vips::Image.new_from_file('public' + result2[:mask_url])
      # Center should still be red (wall)
      pixel = img.getpoint(img.width / 2, img.height / 2)
      expect(pixel[0]).to eq(255)
      expect(pixel[1]).to eq(0)
    end

    it 'returns error for unknown mask_type' do
      result = service.paint_rect(0.0, 0.0, 0.5, 0.5, 'lava')
      expect(result[:success]).to be false
      expect(result[:error]).to include('Unknown mask_type')
    end

    it 'updates room battle_map_wall_mask_url, width, and height' do
      service.paint_rect(0.0, 0.0, 0.5, 0.5, 'wall')
      updated = Room[room.id]
      expect(updated.battle_map_wall_mask_url).not_to be_nil
      expect(updated.battle_map_wall_mask_width).to be_a(Integer)
      expect(updated.battle_map_wall_mask_height).to be_a(Integer)
    end

    it 'returns the mask dimensions in the result' do
      result = service.paint_rect(0.0, 0.0, 0.5, 0.5, 'wall')
      expect(result[:mask_width]).to be_a(Integer)
      expect(result[:mask_height]).to be_a(Integer)
    end

    it 'recomputes edge passability for all hexes in painted area, not only walls' do
      skip 'passable_edges column not available in this schema' unless RoomHex.columns.include?(:passable_edges)

      floor_hex = RoomHex.create(
        room_id: room.id, hex_x: 0, hex_y: 0,
        hex_type: 'normal', traversable: true, danger_level: 0
      )
      wall_hex = RoomHex.create(
        room_id: room.id, hex_x: 2, hex_y: 0,
        hex_type: 'wall', traversable: false, danger_level: 0
      )

      mask_svc = double('WallMaskService')
      allow(WallMaskService).to receive(:new).with(room).and_return(mask_svc)
      allow(mask_svc).to receive(:compute_passable_edges).and_return(42)
      allow(mask_svc).to receive(:hex_to_pixel).and_return([10, 10])
      allow(mask_svc).to receive(:wall_pixel?).and_return(false)

      result = service.paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      expect(result[:success]).to be true

      expect(floor_hex.reload.passable_edges).to eq(42)
      expect(wall_hex.reload.passable_edges).to eq(42)
      expect(floor_hex.majority_floor).to be true
      expect(wall_hex.majority_floor).to be true
    end
  end

  describe '#clear!' do
    it 'clears room mask columns' do
      service.paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      service.clear!
      updated = Room[room.id]
      expect(updated.battle_map_wall_mask_url).to be_nil
    end

    it 'deletes the PNG file' do
      result = service.paint_rect(0.0, 0.0, 1.0, 1.0, 'wall')
      path = 'public' + result[:mask_url]
      service.clear!
      expect(File.exist?(path)).to be false
    end

    it 'succeeds when no mask exists yet' do
      result = service.clear!
      expect(result[:success]).to be true
    end
  end

  describe '#regenerate_wall_features!' do
    it 'updates wall_feature without triggering validation errors from partial selects' do
      skip 'wall_feature column not available in this schema' unless RoomHex.columns.include?(:wall_feature)

      bg_url = "/uploads/battle_maps/room_#{room.id}_bg.png"
      mask_url = "/uploads/battle_maps/room_#{room.id}_wall_mask.png"
      Vips::Image.black(64, 64, bands: 3).write_to_file("public#{bg_url}")
      Vips::Image.black(64, 64, bands: 3).write_to_file("public#{mask_url}")
      room.update(
        battle_map_image_url: bg_url,
        battle_map_wall_mask_url: mask_url
      )

      hex = RoomHex.create(
        room_id: room.id,
        hex_x: 0,
        hex_y: 0,
        hex_type: 'normal',
        traversable: true,
        danger_level: 0
      )

      overlay = Object.new
      def overlay.generate_hex_coordinates
        [[0, 0]]
      end
      def overlay.build_hex_pixel_map(_coords, _min_x, _min_y, _img_w, _img_h)
        { [0, 0] => { hx: 0, hy: 0, px: 10, py: 10 }, hex_size: 8.0 }
      end
      def overlay.apply_wall_features(hex_data, wall_mask_path:)
        return if wall_mask_path.nil? || wall_mask_path.empty?

        hex_data.first[:wall_feature] = 'door'
      end

      stub_const('BattlemapV2::HexOverlayService', Class.new)
      allow(BattlemapV2::HexOverlayService).to receive(:new).and_return(overlay)

      result = service.regenerate_wall_features!
      expect(result[:success]).to be true
      expect(result[:updated_hexes]).to eq(1)
      expect(hex.reload.wall_feature).to eq('door')
    end
  end
end
