# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapTemplateService do
  describe 'DELVE_SHAPES' do
    it 'defines four shape types' do
      expect(BattleMapTemplateService::DELVE_SHAPES.keys).to contain_exactly(
        'rect_vertical', 'rect_horizontal', 'small_chamber', 'large_chamber'
      )
    end

    it 'includes dimensions for each shape' do
      BattleMapTemplateService::DELVE_SHAPES.each do |key, shape|
        expect(shape).to have_key(:w), "#{key} missing :w"
        expect(shape).to have_key(:h), "#{key} missing :h"
        expect(shape).to have_key(:name), "#{key} missing :name"
        expect(shape).to have_key(:desc), "#{key} missing :desc"
      end
    end
  end

  describe '.delve_shape_key' do
    let(:delve_room) { double('DelveRoom', is_boss: false, room_type: 'chamber', available_exits: %w[north south]) }

    context 'for boss rooms' do
      let(:boss_room) { double('DelveRoom', is_boss: true, room_type: 'chamber') }

      it 'returns large_chamber' do
        expect(described_class.delve_shape_key(boss_room)).to eq('large_chamber')
      end
    end

    context 'for corridor with east-west exits' do
      let(:ew_corridor) { double('DelveRoom', is_boss: false, room_type: 'corridor', available_exits: %w[east west]) }

      it 'returns rect_horizontal' do
        expect(described_class.delve_shape_key(ew_corridor)).to eq('rect_horizontal')
      end
    end

    context 'for corridor with north-south exits' do
      let(:ns_corridor) { double('DelveRoom', is_boss: false, room_type: 'corridor', available_exits: %w[north south]) }

      it 'returns rect_vertical' do
        expect(described_class.delve_shape_key(ns_corridor)).to eq('rect_vertical')
      end
    end

    context 'for corridor with mixed exits' do
      let(:mixed) { double('DelveRoom', is_boss: false, room_type: 'corridor', available_exits: %w[north east]) }

      it 'returns rect_vertical when north/south present with east/west' do
        expect(described_class.delve_shape_key(mixed)).to eq('rect_vertical')
      end
    end

    context 'for non-corridor rooms' do
      let(:chamber) { double('DelveRoom', is_boss: false, room_type: 'chamber', available_exits: %w[north]) }

      it 'returns small_chamber' do
        expect(described_class.delve_shape_key(chamber)).to eq('small_chamber')
      end
    end

    context 'for corridor with down exit only' do
      let(:down_only) { double('DelveRoom', is_boss: false, room_type: 'corridor', available_exits: %w[down]) }

      it 'returns rect_vertical (down is excluded)' do
        expect(described_class.delve_shape_key(down_only)).to eq('rect_vertical')
      end
    end
  end

  describe '.apply_to_room!' do
    let(:room) { create(:room) }
    let(:hex_data) do
      [
        { 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal', 'traversable' => true },
        { 'hex_x' => 1, 'hex_y' => 0, 'hex_type' => 'wall', 'traversable' => false },
        { 'hex_x' => 2, 'hex_y' => 0, 'hex_type' => 'water', 'traversable' => true, 'water_type' => 'shallow' }
      ]
    end
    let(:template) do
      BattleMapTemplate.create(
        category: 'delve',
        shape_key: 'small_chamber',
        variant: 0,
        width_feet: 12.0,
        height_feet: 12.0,
        hex_data: Sequel.pg_jsonb_wrap(hex_data),
        image_url: 'https://example.com/map.png',
        description_hint: 'Test chamber'
      )
    end

    it 'creates room hexes from template data' do
      result = described_class.apply_to_room!(template, room)

      expect(result).to be true
      expect(room.room_hexes_dataset.count).to eq(3)
    end

    it 'sets battle map fields on the room' do
      described_class.apply_to_room!(template, room)
      room.reload

      expect(room.has_battle_map).to be true
      expect(room.battle_map_image_url).to eq('https://example.com/map.png')
    end

    it 'preserves hex types correctly' do
      described_class.apply_to_room!(template, room)

      wall_hex = RoomHex.first(room_id: room.id, hex_x: 1, hex_y: 0)
      expect(wall_hex.hex_type).to eq('wall')
      expect(wall_hex.traversable).to be false
    end

    it 'preserves water_type' do
      described_class.apply_to_room!(template, room)

      water_hex = RoomHex.first(room_id: room.id, hex_x: 2, hex_y: 0)
      expect(water_hex.water_type).to eq('shallow')
    end

    it 'replaces existing hexes' do
      RoomHex.multi_insert([{
        room_id: room.id, hex_x: 99, hex_y: 99, hex_type: 'normal',
        danger_level: 0, traversable: true, created_at: Time.now, updated_at: Time.now
      }])

      described_class.apply_to_room!(template, room)
      expect(RoomHex.where(room_id: room.id, hex_x: 99).count).to eq(0)
    end

    it 'touches the template' do
      old_time = template.last_used_at
      described_class.apply_to_room!(template, room)
      template.reload

      # last_used_at should be updated (or set if nil)
      expect(template.last_used_at).not_to be_nil
    end

    context 'when template has object metadata and object_map_url' do
      let(:obj_meta) { { 'barrel' => [{ 'hex_x' => 0, 'hex_y' => 0 }] } }
      let(:template_with_objects) do
        t = BattleMapTemplate.create(
          category: 'delve',
          shape_key: 'small_chamber',
          variant: 2,
          width_feet: 12.0,
          height_feet: 12.0,
          hex_data: Sequel.pg_jsonb_wrap(hex_data),
          image_url: 'https://example.com/map.png',
          description_hint: 'Test chamber with objects'
        )
        cols = BattleMapTemplate.columns
        update_attrs = {}
        update_attrs[:ai_object_metadata] = Sequel.pg_jsonb_wrap(obj_meta) if cols.include?(:ai_object_metadata)
        update_attrs[:object_map_url] = 'https://example.com/objects.png' if cols.include?(:object_map_url)
        t.update(update_attrs) unless update_attrs.empty?
        t.reload
        t
      end

      it 'copies ai_object_metadata to room if columns exist' do
        skip 'ai_object_metadata column not present' unless BattleMapTemplate.columns.include?(:ai_object_metadata) && Room.columns.include?(:battle_map_object_metadata)
        described_class.apply_to_room!(template_with_objects, room)
        room.reload
        expect(room.battle_map_object_metadata).to eq(obj_meta)
      end

      it 'copies object_map_url to room if columns exist' do
        skip 'object_map_url column not present' unless BattleMapTemplate.columns.include?(:object_map_url) && Room.columns.include?(:battle_map_object_map_url)
        described_class.apply_to_room!(template_with_objects, room)
        room.reload
        expect(room.battle_map_object_map_url).to eq('https://example.com/objects.png')
      end
    end

    context 'with empty hex data' do
      let(:empty_template) do
        BattleMapTemplate.create(
          category: 'delve',
          shape_key: 'small_chamber',
          variant: 1,
          width_feet: 12.0,
          height_feet: 12.0,
          hex_data: Sequel.pg_jsonb_wrap([]),
          description_hint: 'Empty'
        )
      end

      it 'returns false' do
        expect(described_class.apply_to_room!(empty_template, room)).to be false
      end
    end
  end

  describe '.apply_random!' do
    let(:room) { create(:room) }

    context 'when no template exists' do
      it 'returns false' do
        result = described_class.apply_random!(category: 'nonexistent', shape_key: 'fake', room: room)
        expect(result).to be false
      end
    end

    context 'when a template exists' do
      before do
        BattleMapTemplate.create(
          category: 'delve',
          shape_key: 'small_chamber',
          variant: 0,
          width_feet: 12.0,
          height_feet: 12.0,
          hex_data: Sequel.pg_jsonb_wrap([{ 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal', 'traversable' => true }]),
          image_url: 'https://example.com/test.png',
          description_hint: 'Test'
        )
      end

      it 'applies the template to the room' do
        result = described_class.apply_random!(category: 'delve', shape_key: 'small_chamber', room: room)
        expect(result).to be true
        expect(room.reload.has_battle_map).to be true
      end
    end
  end

  describe '.store_template_from_room (private)' do
    let(:shape) { BattleMapTemplateService::DELVE_SHAPES['small_chamber'] }

    context 'when room has object metadata and object_map_url' do
      let(:obj_meta) { { 'chest' => [{ 'hex_x' => 2, 'hex_y' => 4 }] } }
      let(:room_with_objects) do
        r = create(:room)
        update_attrs = {}
        update_attrs[:battle_map_object_metadata] = Sequel.pg_jsonb_wrap(obj_meta) if Room.columns.include?(:battle_map_object_metadata)
        update_attrs[:battle_map_object_map_url] = 'https://example.com/obj_mask.png' if Room.columns.include?(:battle_map_object_map_url)
        r.update(update_attrs) unless update_attrs.empty?
        r.reload
        r
      end

      it 'copies battle_map_object_metadata into template ai_object_metadata if columns exist' do
        skip 'Required columns not present' unless Room.columns.include?(:battle_map_object_metadata) && BattleMapTemplate.columns.include?(:ai_object_metadata)
        template = described_class.send(:store_template_from_room, room_with_objects,
                                        category: 'delve', shape_key: 'small_chamber', variant: 9, shape: shape)
        expect(template.ai_object_metadata).to eq(obj_meta)
      end

      it 'copies battle_map_object_map_url into template object_map_url if columns exist' do
        skip 'Required columns not present' unless Room.columns.include?(:battle_map_object_map_url) && BattleMapTemplate.columns.include?(:object_map_url)
        template = described_class.send(:store_template_from_room, room_with_objects,
                                        category: 'delve', shape_key: 'small_chamber', variant: 9, shape: shape)
        expect(template.object_map_url).to eq('https://example.com/obj_mask.png')
      end
    end
  end

  describe '.generate_template!' do
    it 'raises for unknown shape key' do
      expect {
        described_class.generate_template!(category: 'delve', shape_key: 'nonexistent')
      }.to raise_error(RuntimeError, /Unknown shape/)
    end
  end
end
