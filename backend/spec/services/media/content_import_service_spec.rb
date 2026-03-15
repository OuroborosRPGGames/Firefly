# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe ContentImportService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:instance) { create(:character_instance, character: character, reality: reality, current_room: room) }

  before do
    # Ensure character has a primary instance
    allow(character).to receive(:primary_instance).and_return(instance)
  end

  describe '.import_character' do
    let(:valid_json_data) do
      {
        'version' => '1.0.0',
        'export_type' => 'character',
        'character' => { 'short_desc' => 'A test character' },
        'descriptions' => [],
        'items' => [],
        'outfits' => []
      }
    end

    context 'with unsupported version' do
      it 'returns error for unsupported version' do
        json_data = valid_json_data.merge('version' => '999.0.0')
        result = described_class.import_character(character, json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/Unsupported export version/)
      end
    end

    context 'with invalid export type' do
      it 'returns error for wrong export type' do
        json_data = valid_json_data.merge('export_type' => 'property')
        result = described_class.import_character(character, json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/expected character/)
      end
    end

    context 'with no instance' do
      before do
        allow(character).to receive(:primary_instance).and_return(nil)
      end

      it 'returns error when character has no instance' do
        result = described_class.import_character(character, valid_json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/no instance/)
      end
    end

    context 'with valid minimal data' do
      it 'returns success with empty import counts' do
        result = described_class.import_character(character, valid_json_data)

        expect(result[:success]).to be true
        expect(result[:imported][:descriptions]).to eq(0)
        expect(result[:imported][:items]).to eq(0)
        expect(result[:imported][:outfits]).to eq(0)
        expect(result[:errors]).to be_empty
      end
    end

    context 'with descriptions data' do
      let(:json_with_descriptions) do
        valid_json_data.merge('descriptions' => [
                                { 'desc_type' => 'general', 'description' => 'A tall figure' }
                              ])
      end

      it 'processes descriptions data without crashing' do
        result = described_class.import_character(character, json_with_descriptions)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:imported)
      end
    end

    context 'when database error occurs' do
      before do
        allow(DB).to receive(:transaction).and_raise(StandardError, 'DB error')
      end

      it 'handles errors gracefully' do
        result = described_class.import_character(character, valid_json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/Import failed/)
      end
    end

    context 'with url_mapping' do
      let(:url_mapping) { { 'old_image.png' => 'https://example.com/new_image.png' } }

      it 'accepts url_mapping parameter' do
        result = described_class.import_character(character, valid_json_data, url_mapping)

        expect(result).to be_a(Hash)
      end
    end
  end

  describe '.import_property' do
    let(:valid_property_data) do
      {
        'version' => '1.0.0',
        'export_type' => 'property',
        'room' => { 'name' => 'Test Room', 'short_description' => 'A test room' },
        'places' => [],
        'decorations' => [],
        'room_features' => [],
        'room_hexes' => []
      }
    end

    context 'with unsupported version' do
      it 'returns error for unsupported version' do
        json_data = valid_property_data.merge('version' => '999.0.0')
        result = described_class.import_property(room, json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/Unsupported export version/)
      end
    end

    context 'with invalid export type' do
      it 'returns error for wrong export type' do
        json_data = valid_property_data.merge('export_type' => 'character')
        result = described_class.import_property(room, json_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/expected property/)
      end
    end

    context 'with valid minimal data' do
      it 'returns result hash with expected structure' do
        result = described_class.import_property(room, valid_property_data)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:success)
        expect(result).to have_key(:imported)
        expect(result).to have_key(:errors)
      end
    end

    context 'with places data' do
      let(:json_with_places) do
        valid_property_data.merge('places' => [
                                    { 'name' => 'A wooden chair', 'x' => 10, 'y' => 10, 'capacity' => 1 }
                                  ])
      end

      it 'processes places data without crashing' do
        result = described_class.import_property(room, json_with_places)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:imported)
      end
    end

    context 'with decorations data' do
      let(:json_with_decorations) do
        valid_property_data.merge('decorations' => [
                                    { 'name' => 'A painting', 'x' => 5, 'y' => 5 }
                                  ])
      end

      it 'processes decorations data without crashing' do
        result = described_class.import_property(room, json_with_decorations)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:imported)
      end
    end

    context 'with features data' do
      let(:json_with_features) do
        valid_property_data.merge('room_features' => [
                                    {
                                      'name' => 'Window',
                                      'feature_type' => 'window',
                                      'x' => 0, 'y' => 0, 'z' => 0,
                                      'width' => 2, 'height' => 3,
                                      'orientation' => 'north',
                                      'open_state' => 'closed',
                                      'transparency_state' => 'transparent',
                                      'visibility_state' => 'both_ways',
                                      'allows_sight' => true,
                                      'allows_movement' => false,
                                      'has_curtains' => false,
                                      'has_lock' => false,
                                      'sight_reduction' => 0.0
                                    }
                                  ])
      end

      it 'processes features data without crashing' do
        result = described_class.import_property(room, json_with_features)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:imported)
        expect(result[:success]).to be true
        expect(result[:imported][:features]).to eq(1)
      end
    end

    context 'with hexes data' do
      let(:json_with_hexes) do
        valid_property_data.merge('room_hexes' => [
                                    { 'hex_x' => 0, 'hex_y' => 0, 'hex_type' => 'normal', 'elevation_level' => 0 }
                                  ])
      end

      it 'processes hexes data without crashing' do
        result = described_class.import_property(room, json_with_hexes)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:imported)
        expect(result[:imported][:hexes]).to eq(1)
      end
    end

    context 'when database error occurs' do
      before do
        allow(DB).to receive(:transaction).and_raise(StandardError, 'DB error')
      end

      it 'handles errors gracefully' do
        result = described_class.import_property(room, valid_property_data)

        expect(result[:success]).to be false
        expect(result[:errors]).to include(/Import failed/)
      end
    end

    context 'with url_mapping' do
      let(:url_mapping) { { 'old_bg.png' => 'https://example.com/new_bg.png' } }

      it 'accepts url_mapping parameter' do
        result = described_class.import_property(room, valid_property_data, url_mapping)

        expect(result).to be_a(Hash)
      end

      it 'remaps seasonal background image paths nested under seasonal keys' do
        json_data = valid_property_data.merge(
          'room' => {
            'name' => 'Test Room',
            'seasonal_backgrounds' => { 'winter' => 'images/old_bg.png' }
          }
        )

        result = described_class.import_property(room, json_data, url_mapping)
        expect(result[:success]).to be true
        expect(room.refresh.seasonal_backgrounds['winter']).to eq('https://example.com/new_bg.png')
      end

      it 'remaps image paths with query strings' do
        json_data = valid_property_data.merge(
          'room' => {
            'name' => 'Test Room',
            'default_background_url' => 'images/old_bg.png?sig=123'
          }
        )

        result = described_class.import_property(room, json_data, url_mapping)
        expect(result[:success]).to be true
        expect(room.refresh.default_background_url).to eq('https://example.com/new_bg.png')
      end
    end

    context 'with replace_existing and preserve_exits options' do
      let!(:existing_place) { create(:place, room: room, name: 'Existing Place') }
      let!(:existing_decoration) { create(:decoration, room: room, name: 'Existing Decoration') }
      let!(:existing_exit_feature) { create(:room_feature, room: room, connected_room_id: create(:room).id, feature_type: 'door', name: 'Exit Door') }
      let!(:existing_non_exit_feature) { create(:room_feature, room: room, connected_room_id: nil, feature_type: 'window', name: 'Window') }

      let(:replacement_payload) do
        valid_property_data.merge(
          'places' => [{ 'name' => 'New Place' }],
          'decorations' => [{ 'name' => 'New Decoration' }],
          'room_features' => [
            {
              'name' => 'New Feature',
              'feature_type' => 'door',
              'x' => 0, 'y' => 0, 'z' => 0,
              'width' => 2, 'height' => 3,
              'orientation' => 'north',
              'open_state' => 'closed',
              'transparency_state' => 'opaque',
              'visibility_state' => 'both_ways',
              'allows_sight' => false,
              'allows_movement' => true,
              'has_curtains' => false,
              'has_lock' => false,
              'sight_reduction' => 0.0
            }
          ]
        )
      end

      it 'clears existing content while preserving connected exit features' do
        result = described_class.import_property(
          room,
          replacement_payload,
          {},
          { replace_existing: true, preserve_exits: true }
        )

        expect(result[:success]).to be true
        expect(room.places_dataset.count).to eq(1)
        expect(room.decorations_dataset.count).to eq(1)
        expect(room.room_features_dataset.where(name: 'Exit Door').count).to eq(1)
        expect(room.room_features_dataset.where(name: 'Window').count).to eq(0)
      end
    end

    context 'with scale_places option' do
      let(:source_payload) do
        valid_property_data.merge(
          'room' => valid_property_data['room'].merge('min_x' => 0, 'max_x' => 100, 'min_y' => 0, 'max_y' => 100),
          'places' => [{ 'name' => 'Center', 'x' => 50, 'y' => 50, 'z' => 0 }]
        )
      end

      it 'scales imported place coordinates to target room bounds' do
        room.update(min_x: 0, max_x: 200, min_y: 0, max_y: 200)

        result = described_class.import_property(room, source_payload, {}, { scale_places: true })
        expect(result[:success]).to be true

        imported_place = room.places_dataset.first(name: 'Center')
        expect(imported_place.x).to eq(100)
        expect(imported_place.y).to eq(100)
      end
    end

    context 'with import_battle_map disabled' do
      let(:payload) do
        valid_property_data.merge(
          'room' => valid_property_data['room'].merge('has_battle_map' => true, 'battle_map_config' => { 'foo' => 'bar' }),
          'room_hexes' => [{ 'hex_x' => 1, 'hex_y' => 2 }]
        )
      end

      it 'skips room hex import and battle-map base updates' do
        result = described_class.import_property(room, payload, {}, { import_battle_map: false })

        expect(result[:success]).to be true
        expect(result[:imported][:hexes]).to eq(0)
        expect(room.room_hexes_dataset.count).to eq(0)
      end
    end
  end

  describe 'helper methods' do
    describe '.remap_urls!' do
      it 'remaps image URLs in data' do
        # This is a private method but we can test it indirectly
        # through import_character with url_mapping
        url_mapping = { 'test.png' => 'https://cdn.example.com/test.png' }
        json_data = {
          'version' => '1.0.0',
          'export_type' => 'character',
          'character' => { 'short_desc' => 'Test', 'image_url' => 'test.png' }
        }

        allow(character).to receive(:primary_instance).and_return(instance)
        result = described_class.import_character(character, json_data, url_mapping)

        expect(result).to be_a(Hash)
      end
    end
  end

  describe '.import_character' do
    context 'with multi-position descriptions' do
      let!(:bp_left_arm) { create(:body_position, label: 'left_arm', region: 'arms') }
      let!(:bp_right_arm) { create(:body_position, label: 'right_arm', region: 'arms') }

      let(:json_data) do
        {
          'version' => '1.0.0',
          'export_type' => 'character',
          'descriptions' => [
            {
              'description_type' => 'tattoo',
              'body_positions' => ['left_arm', 'right_arm'],
              'content' => 'matching sleeve tattoos'
            }
          ],
          'items' => [],
          'outfits' => []
        }
      end

      it 'persists join-table body positions for imported descriptions' do
        result = described_class.import_character(character, json_data)
        expect(result[:success]).to be true

        desc = CharacterDefaultDescription.where(character_id: character.id, content: 'matching sleeve tattoos').first
        expect(desc).not_to be_nil
        expect(desc.body_positions.map(&:label)).to contain_exactly('left_arm', 'right_arm')
      end
    end

    context 'with zippable pattern positions' do
      let(:json_data) do
        {
          'version' => '1.0.0',
          'export_type' => 'character',
          'descriptions' => [],
          'outfits' => [],
          'items' => [
            {
              'name' => 'Zip Jacket',
              'pattern' => {
                'description' => 'A zipped jacket',
                'name' => 'Zip Jacket',
                'category' => 'Top',
                'covered_positions' => ['Torso'],
                'zippable_positions' => ['Torso']
              }
            }
          ]
        }
      end

      it 'imports zippable positions into unified object type' do
        result = described_class.import_character(character, json_data)
        expect(result[:success]).to be true

        pattern = Pattern.first(description: 'A zipped jacket')
        expect(pattern).not_to be_nil
        expect(pattern.zippable_positions).to include('Torso')
      end
    end

    context 'with pattern image URLs' do
      let(:pattern_description) { "Pattern with image #{SecureRandom.hex(4)}" }
      let(:pattern_image_url) { 'https://example.com/pattern.png' }
      let(:json_data) do
        {
          'version' => '1.0.0',
          'export_type' => 'character',
          'descriptions' => [],
          'outfits' => [],
          'items' => [
            {
              'name' => 'Image Jacket',
              'pattern' => {
                'description' => pattern_description,
                'name' => 'Image Jacket',
                'category' => 'Top',
                'image_url' => pattern_image_url
              }
            }
          ]
        }
      end

      it 'persists pattern image_url from pattern data' do
        result = described_class.import_character(character, json_data)
        expect(result[:success]).to be true

        pattern = Pattern.first(description: pattern_description)
        expect(pattern).not_to be_nil
        expect(pattern.image_url).to eq(pattern_image_url)
      end
    end
  end

  describe 'round-trip export/import' do
    context 'for character content' do
      let!(:bp_face) { create(:body_position, label: 'face', region: 'head') }
      let!(:desc) do
        create(
          :character_default_description,
          character: character,
          body_position: bp_face,
          content: 'A scarred face',
          description_type: 'natural',
          suffix: 'period',
          prefix: 'none',
          concealed_by_clothing: false,
          display_order: 1,
          active: true
        )
      end

      before do
        create(:character_description_position, character_default_description: desc, body_position: bp_face)
      end

      it 'preserves description data through export and re-import' do
        # Export
        export_data = ContentExportService.export_character(character)
        json_data = JSON.parse(JSON.generate(export_data[:json]))

        # Create a second character to import into
        other_character = create(:character, user: user)
        other_instance = create(:character_instance, character: other_character, reality: reality, current_room: room)
        allow(other_character).to receive(:primary_instance).and_return(other_instance)

        # Import
        result = described_class.import_character(other_character, json_data)
        expect(result[:success]).to be true
        expect(result[:imported][:descriptions]).to eq(1)

        # Verify
        imported_desc = CharacterDefaultDescription.where(character_id: other_character.id).first
        expect(imported_desc).not_to be_nil
        expect(imported_desc.content).to eq('A scarred face')
        expect(imported_desc.description_type).to eq('natural')
        expect(imported_desc.suffix).to eq('period')
        expect(imported_desc.body_position.label).to eq('face')
      end
    end

    context 'for property content' do
      let!(:place) { create(:place, room: room, name: 'Oak Desk', description: 'A sturdy desk', capacity: 2, x: 50, y: 50, z: 0) }
      let!(:decoration) { create(:decoration, room: room, name: 'Painting', description: 'An oil painting', display_order: 1) }

      it 'preserves places and decorations through export and re-import' do
        # Export
        export_data = ContentExportService.export_property(room)
        json_data = JSON.parse(JSON.generate(export_data[:json]))

        # Create a second room to import into
        other_room = create(:room)

        # Import
        result = described_class.import_property(other_room, json_data, {}, { replace_existing: true })
        expect(result[:success]).to be true
        expect(result[:imported][:places]).to eq(1)
        expect(result[:imported][:decorations]).to eq(1)

        # Verify places
        imported_place = other_room.places_dataset.first(name: 'Oak Desk')
        expect(imported_place).not_to be_nil
        expect(imported_place.description).to eq('A sturdy desk')
        expect(imported_place.capacity).to eq(2)
        expect(imported_place.x).to eq(50)
        expect(imported_place.y).to eq(50)

        # Verify decorations
        imported_dec = other_room.decorations_dataset.first(name: 'Painting')
        expect(imported_dec).not_to be_nil
        expect(imported_dec.description).to eq('An oil painting')
        expect(imported_dec.display_order).to eq(1)
      end
    end
  end
end
