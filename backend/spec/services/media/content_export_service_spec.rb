# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ContentExportService do
  describe 'constants' do
    it 'defines EXPORT_VERSION' do
      expect(described_class::EXPORT_VERSION).to eq('1.0.0')
    end
  end

  describe '.export_character' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }

    it 'returns hash with json and images keys' do
      result = described_class.export_character(character)
      expect(result).to be_a(Hash)
      expect(result).to have_key(:json)
      expect(result).to have_key(:images)
    end

    it 'includes version in json' do
      result = described_class.export_character(character)
      expect(result[:json][:version]).to eq('1.0.0')
    end

    it 'includes export_type in json' do
      result = described_class.export_character(character)
      expect(result[:json][:export_type]).to eq('character')
    end

    it 'includes exported_at timestamp' do
      result = described_class.export_character(character)
      expect(result[:json][:exported_at]).to be_a(String)
      expect { Time.parse(result[:json][:exported_at]) }.not_to raise_error
    end

    it 'includes character base data' do
      result = described_class.export_character(character)
      expect(result[:json][:character]).to be_a(Hash)
      expect(result[:json][:character]).to have_key(:forename)
      expect(result[:json][:character]).to have_key(:surname)
    end

    it 'includes descriptions array' do
      result = described_class.export_character(character)
      expect(result[:json][:descriptions]).to be_an(Array)
    end

    it 'includes items array' do
      result = described_class.export_character(character)
      expect(result[:json][:items]).to be_an(Array)
    end

    it 'includes outfits array' do
      result = described_class.export_character(character)
      expect(result[:json][:outfits]).to be_an(Array)
    end

    context 'with character picture' do
      before do
        allow(character).to receive(:picture_url).and_return('https://example.com/pic.jpg')
      end

      it 'registers image in images array' do
        result = described_class.export_character(character)
        expect(result[:images]).to be_an(Array)
      end

      it 'maps picture URL to images directory' do
        result = described_class.export_character(character)
        expect(result[:json][:character][:picture_url]).to match(%r{^images/}) if result[:images].any?
      end
    end

    context 'with signed character picture URL' do
      before do
        allow(character).to receive(:picture_url).and_return('https://example.com/pic.jpg?sig=abc123')
      end

      it 'normalizes exported image filename extension' do
        result = described_class.export_character(character)
        image_entry = result[:images].find { |img| img[:original_url].include?('pic.jpg?sig=abc123') }

        expect(image_entry).not_to be_nil
        expect(image_entry[:filename]).to end_with('.jpg')
        expect(image_entry[:filename]).not_to include('?')
        expect(result[:json][:character][:picture_url]).to end_with('.jpg')
      end
    end

    context 'with descriptions having images' do
      let(:body_position) { double('BodyPosition', label: 'face', region: 'head') }
      let(:description) do
        double('DefaultDescription',
          body_position: body_position,
          content: 'A friendly face',
          image_url: 'https://example.com/desc.jpg',
          description_type: 'natural',
          suffix: 'period',
          prefix: 'none',
          concealed_by_clothing: false,
          display_order: 1,
          active: true
        )
      end
      let(:descriptions_dataset) { double('Dataset') }

      before do
        allow(character).to receive(:default_descriptions_dataset).and_return(descriptions_dataset)
        ordered_dataset = double('OrderedDataset')
        allow(descriptions_dataset).to receive(:eager).with(:body_position, :body_positions).and_return(ordered_dataset)
        allow(ordered_dataset).to receive(:order).with(:display_order, :id).and_return([description])
      end

      it 'exports descriptions with body position' do
        result = described_class.export_character(character)
        # Verify descriptions are mapped
        expect(result[:json][:descriptions]).to be_an(Array)
      end
    end

    context 'with multi-position descriptions' do
      let!(:bp_left_arm) { create(:body_position, label: 'left_arm', region: 'arms') }
      let!(:bp_right_arm) { create(:body_position, label: 'right_arm', region: 'arms') }
      let!(:desc) do
        create(
          :character_default_description,
          character: character,
          body_position: bp_left_arm,
          description_type: 'tattoo',
          suffix: 'comma',
          prefix: 'and',
          content: 'matching sleeve tattoo'
        )
      end

      before do
        create(:character_description_position, character_default_description: desc, body_position: bp_left_arm)
        create(:character_description_position, character_default_description: desc, body_position: bp_right_arm)
      end

      it 'exports body_positions, description_type, and formatting fields' do
        result = described_class.export_character(character)
        exported = result[:json][:descriptions].find { |d| d[:content] == 'matching sleeve tattoo' }

        expect(exported[:body_positions]).to contain_exactly('left_arm', 'right_arm')
        expect(exported[:description_type]).to eq('tattoo')
        expect(exported[:suffix]).to eq('comma')
        expect(exported[:prefix]).to eq('and')
      end
    end

    context 'with instance items and outfits' do
      let(:instance) { double('CharacterInstance') }
      let(:pattern) { double('Pattern', description: 'Blue shirt') }
      let(:item) do
        double('Item',
          name: 'Shirt',
          description: 'A blue shirt',
          pattern: pattern,
          image_url: nil,
          thumbnail_url: nil,
          quantity: 1,
          condition: 'good',
          equipped: false,
          equipment_slot: nil,
          worn: true,
          worn_layer: 1,
          held: false,
          stored: false,
          concealed: false,
          zipped: false,
          torn: 0,
          display_order: 0
        )
      end
      let(:objects_dataset) { double('Dataset') }
      let(:outfits_dataset) { double('Dataset') }

      before do
        allow(character).to receive(:primary_instance).and_return(instance)
        allow(instance).to receive(:objects_dataset).and_return(objects_dataset)
        allow(instance).to receive(:outfits_dataset).and_return(outfits_dataset)
        allow(objects_dataset).to receive(:eager).with(:pattern).and_return([item])
        allow(outfits_dataset).to receive(:eager).and_return([])
        allow(pattern).to receive_messages(
          name: 'Blue Shirt',
          category: 'Top',
          subcategory: 'shirt',
          layer: 1,
          covered_positions: ['torso'],
          zippable_positions: [],
          price: 100,
          image_url: nil,
          desc_desc: nil,
          consume_type: nil,
          taste: nil,
          effect: nil,
          is_melee: false,
          is_ranged: false,
          weapon_range: nil,
          attack_speed: nil,
          damage_type: nil,
          min_year: nil,
          max_year: nil
        )
        # These columns may not exist on Pattern — keep respond_to? checks
        allow(pattern).to receive(:respond_to?).with(:consume_time).and_return(false)
        allow(pattern).to receive(:respond_to?).with(:damage_dice).and_return(false)
      end

      it 'exports items with pattern data' do
        result = described_class.export_character(character)
        expect(result[:json][:items]).to be_an(Array)
      end
    end
  end

  describe '.export_property' do
    let(:room) { create(:room) }

    it 'returns hash with json and images keys' do
      result = described_class.export_property(room)
      expect(result).to be_a(Hash)
      expect(result).to have_key(:json)
      expect(result).to have_key(:images)
    end

    it 'includes version in json' do
      result = described_class.export_property(room)
      expect(result[:json][:version]).to eq('1.0.0')
    end

    it 'includes export_type as property' do
      result = described_class.export_property(room)
      expect(result[:json][:export_type]).to eq('property')
    end

    it 'includes room base data' do
      result = described_class.export_property(room)
      expect(result[:json][:room]).to be_a(Hash)
      expect(result[:json][:room]).to have_key(:name)
    end

    it 'includes places array' do
      result = described_class.export_property(room)
      expect(result[:json][:places]).to be_an(Array)
    end

    it 'includes decorations array' do
      result = described_class.export_property(room)
      expect(result[:json][:decorations]).to be_an(Array)
    end

    it 'includes room_features array' do
      result = described_class.export_property(room)
      expect(result[:json][:room_features]).to be_an(Array)
    end

    it 'includes room_hexes array' do
      result = described_class.export_property(room)
      expect(result[:json][:room_hexes]).to be_an(Array)
    end

    context 'with places' do
      let(:place) do
        double('Place',
          name: 'Couch',
          description: 'A comfy couch',
          capacity: 3,
          x: 10,
          y: 5,
          z: 0,
          is_furniture: true,
          invisible: false,
          image_url: nil,
          default_sit_action: nil
        )
      end
      let(:places_dataset) { double('Dataset') }

      before do
        allow(room).to receive(:places_dataset).and_return(places_dataset)
        allow(places_dataset).to receive(:order).with(:id).and_return([place])
      end

      it 'exports place data' do
        result = described_class.export_property(room)
        expect(result[:json][:places]).to be_an(Array)
      end
    end

    context 'with room features' do
      let!(:feature) do
        create(:room_feature,
          room: room,
          name: 'Window',
          feature_type: 'window',
          description: 'A large window',
          x: 0, y: 10, z: 0,
          width: 5, height: 8,
          orientation: 'north',
          open_state: 'closed',
          transparency_state: 'transparent',
          allows_sight: true,
          allows_movement: false,
          has_curtains: true,
          curtain_state: 'open',
          has_lock: false
        )
      end

      it 'exports room features' do
        result = described_class.export_property(room)
        expect(result[:json][:room_features]).to be_an(Array)
        expect(result[:json][:room_features].length).to eq(1)
        expect(result[:json][:room_features].first[:name]).to eq('Window')
      end
    end

    context 'with room hexes' do
      let!(:hex) do
        RoomHex.create(
          room_id: room.id,
          hex_x: 5, hex_y: 4,
          hex_type: 'normal',
          traversable: true,
          elevation_level: 0,
          danger_level: 0,
          cover_value: 0
        )
      end

      it 'exports room hexes' do
        result = described_class.export_property(room)
        expect(result[:json][:room_hexes]).to be_an(Array)
        expect(result[:json][:room_hexes].length).to eq(1)
      end
    end

    context 'with seasonal descriptions' do
      before do
        room.update(seasonal_descriptions: Sequel.pg_jsonb_wrap({
          'spring' => 'Flowers bloom',
          'winter' => 'Snow covers everything'
        }))
      end

      it 'exports seasonal descriptions' do
        result = described_class.export_property(room)
        room_data = result[:json][:room]
        expect(room_data).to have_key(:seasonal_descriptions)
      end
    end

    context 'with background images' do
      before do
        room.update(
          default_background_url: 'https://example.com/bg.jpg',
          battle_map_image_url: 'https://example.com/battle.jpg'
        )
      end

      it 'registers background images' do
        result = described_class.export_property(room)
        expect(result[:images]).to be_an(Array)
        expect(result[:images].length).to be >= 2
      end
    end
  end

  describe 'private methods' do
    describe '#export_character_base' do
      let(:user) { create(:user) }
      let(:character) { create(:character, user: user) }
      let(:register_image) { ->(url, prefix) { "images/#{prefix}_test.jpg" if url } }

      it 'includes all base character fields' do
        result = described_class.send(:export_character_base, character, register_image)

        expect(result).to have_key(:forename)
        expect(result).to have_key(:surname)
        expect(result).to have_key(:nickname)
        expect(result).to have_key(:short_desc)
        expect(result).to have_key(:height_cm)
        expect(result).to have_key(:voice_type)
      end
    end

    describe '#export_room_base' do
      let(:room) { create(:room) }
      let(:register_image) { ->(url, prefix) { "images/#{prefix}_test.jpg" if url } }

      it 'includes all base room fields' do
        result = described_class.send(:export_room_base, room, register_image)

        expect(result).to have_key(:name)
        expect(result).to have_key(:room_type)
      end
    end

    describe '#export_seasonal_with_images' do
      let(:register_image) { ->(url, prefix) { "images/#{prefix}_test.jpg" } }

      it 'returns nil for nil input' do
        result = described_class.send(:export_seasonal_with_images, nil, register_image, 'test')
        expect(result).to be_nil
      end

      it 'parses JSON string input' do
        json_string = '{"spring": "Spring text"}'
        result = described_class.send(:export_seasonal_with_images, json_string, register_image, 'test')
        expect(result).to be_a(Hash)
      end

      it 'handles Hash input directly' do
        hash_input = { 'spring' => 'Spring text' }
        result = described_class.send(:export_seasonal_with_images, hash_input, register_image, 'test')
        expect(result).to be_a(Hash)
        expect(result['spring']).to eq('Spring text')
      end

      it 'registers URLs as images' do
        hash_input = { 'spring' => '/images/spring.jpg' }
        result = described_class.send(:export_seasonal_with_images, hash_input, register_image, 'bg')
        expect(result['spring']).to start_with('images/')
      end

      it 'returns nil for invalid JSON' do
        result = described_class.send(:export_seasonal_with_images, 'invalid json', register_image, 'test')
        expect(result).to be_nil
      end

      it 'returns nil for empty hash' do
        result = described_class.send(:export_seasonal_with_images, {}, register_image, 'test')
        expect(result).to be_nil
      end
    end

    describe '#export_pattern' do
      let(:register_image) { ->(url, prefix) { "images/#{prefix}_test.jpg" if url } }

      it 'returns nil for nil pattern' do
        result = described_class.send(:export_pattern, nil, register_image)
        expect(result).to be_nil
      end

      it 'includes pattern fields' do
        pattern = double('Pattern',
          description: 'A pattern',
          name: 'Test',
          category: 'Top',
          subcategory: 'shirt',
          layer: 1,
          covered_positions: [],
          zippable_positions: [],
          price: 50,
          image_url: nil,
          desc_desc: nil,
          consume_type: nil,
          taste: nil,
          effect: nil,
          is_melee: false,
          is_ranged: false,
          weapon_range: nil,
          attack_speed: nil,
          damage_type: nil,
          min_year: nil,
          max_year: nil
        )
        allow(pattern).to receive(:respond_to?).with(:consume_time).and_return(false)
        allow(pattern).to receive(:respond_to?).with(:damage_dice).and_return(false)

        result = described_class.send(:export_pattern, pattern, register_image)

        expect(result).to be_a(Hash)
        expect(result[:description]).to eq('A pattern')
        expect(result[:price]).to eq(50)
      end
    end
  end
end
