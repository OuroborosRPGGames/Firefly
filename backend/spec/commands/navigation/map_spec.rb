# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Map, type: :command do
  let(:location) { create(:location) }
  let!(:room) do
    create(:room,
           name: 'Test Room', location: location,
           short_description: 'A test room', room_type: 'standard',
           min_x: 0, max_x: 100, min_y: 0, max_y: 100)
  end
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let!(:character_instance) do
    create(:character_instance,
           character: character, current_room: room,
           x: 50.0, y: 50.0)
  end

  subject(:command) { described_class.new(character_instance) }

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('map')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('viewmap', 'maps')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'has info output_category' do
      expect(described_class.output_category).to eq(:info)
    end
  end

  describe '#execute' do
    context 'with no arguments (shows menu)' do
      it 'returns a quickmenu' do
        result = command.execute('')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      it 'includes map options' do
        result = command.execute('')
        expect(result[:data][:options].map { |o| o[:key] }).to include('room', 'area', 'city', 'mini')
      end
    end

    context 'with room argument' do
      it 'returns a canvas format' do
        result = command.execute('map room')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:canvas)
      end

      it 'returns canvas with correct format' do
        result = command.execute('map room')
        # Format: width|||height|||commands
        parts = result[:message].split('|||')
        expect(parts.length).to eq(3)
        expect(parts[0]).to match(/^\d+$/) # width
        expect(parts[1]).to match(/^\d+$/) # height
      end

      it 'includes room boundary lines' do
        result = command.execute('map room')
        expect(result[:message]).to include('line::')
      end

      it 'includes self marker' do
        result = command.execute('map room')
        expect(result[:message]).to include('fcircle::#ff4444')
      end

      it 'includes room name' do
        result = command.execute('map room')
        expect(result[:message]).to include('Test Room')
      end

      it 'includes structured data' do
        result = command.execute('map room')
        expect(result[:data][:room_id]).to eq(room.id)
      end

      it 'targets the right observe window' do
        result = command.execute('map room')
        expect(result[:target_panel]).to eq(:right_observe_window)
      end
    end

    context 'with area argument' do
      context 'when location has hex coordinates' do
        let!(:world) { location.zone.world }
        let!(:location_with_coords) do
          create(:location,
                 zone: location.zone, location_type: 'outdoor',
                 globe_hex_id: 100, latitude: 10.0, longitude: 10.0, world_id: world.id)
        end
        let!(:room_with_coords) do
          create(:room,
                 name: 'Coord Room', location: location_with_coords,
                 short_description: 'A room with coords', room_type: 'standard')
        end
        let!(:char_instance_with_coords) do
          create(:character_instance,
                 character: create(:character, user: create(:user)),
                 current_room: room_with_coords, x: 50.0, y: 50.0)
        end

        subject(:command_with_coords) { described_class.new(char_instance_with_coords) }

        it 'renders area map when location has coordinates' do
          result = command_with_coords.execute('map area')
          expect(result[:success]).to be true
          expect(result[:type]).to eq(:svg)
          expect(result[:data][:action]).to eq('zonemap')
        end
      end

      context 'when location has world/globe IDs but missing lat/lon' do
        let!(:world) { location.zone.world }
        let!(:location_missing_latlon) do
          create(:location,
                 zone: location.zone, location_type: 'outdoor',
                 globe_hex_id: 101, latitude: nil, longitude: nil, world_id: world.id)
        end
        let!(:room_missing_latlon) do
          create(:room,
                 name: 'No LatLon Room', location: location_missing_latlon,
                 short_description: 'A room without map coords', room_type: 'standard')
        end
        let!(:char_instance_missing_latlon) do
          create(:character_instance,
                 character: create(:character, user: create(:user)),
                 current_room: room_missing_latlon, x: 50.0, y: 50.0)
        end

        subject(:command_missing_latlon) { described_class.new(char_instance_missing_latlon) }

        it 'returns an error about missing latitude/longitude' do
          result = command_missing_latlon.execute('map area')
          expect(result[:success]).to be false
          expect(result[:message]).to match(/missing map coordinates/i)
        end
      end

      context 'when location lacks hex coordinates' do
        it 'returns an error about missing coordinates' do
          result = command.execute('map area')
          expect(result[:success]).to be false
          # Message may be HTML-escaped, so check for the key part without apostrophe
          expect(result[:message]).to match(/have world coordinates/)
        end
      end
    end

    context 'with city argument' do
      let!(:street_room) do
        create(:room,
               name: 'Main Street', location: location, room_type: 'street',
               min_x: 0, max_x: 200, min_y: 45, max_y: 55, indoors: false)
      end

      it 'returns SVG format' do
        result = command.execute('map city')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:svg)
      end

      it 'returns SVG content in message' do
        result = command.execute('map city')
        expect(result[:message]).to include('<svg')
      end

      it 'includes SVG in data' do
        result = command.execute('map city')
        expect(result[:data][:svg]).to include('<svg')
      end

      it 'targets the right observe window' do
        result = command.execute('map city')
        expect(result[:target_panel]).to eq(:right_observe_window)
      end

      it 'includes location metadata' do
        result = command.execute('map city')
        expect(result[:data][:action]).to eq('citymap')
        expect(result[:data][:location_id]).to eq(location.id)
      end

      it 'includes render service metadata' do
        result = command.execute('map city')
        expect(result[:data][:center_room_id]).to eq(room.id)
        expect(result[:data][:mode]).to eq(:city)
      end

      it 'does not use type :temp' do
        result = command.execute('map city')
        expect(result[:type]).not_to eq(:temp)
      end

      context 'when not in a location' do
        before do
          allow(room).to receive(:location).and_return(nil)
          allow(command).to receive(:location).and_return(room)
        end

        it 'returns an error' do
          result = command.execute('map city')
          expect(result[:success]).to be false
        end
      end
    end

    context 'with mini argument' do
      before do
        allow(character_instance).to receive(:toggle_minimap!)
        allow(character_instance).to receive(:minimap_enabled?).and_return(true)
      end

      it 'targets the left minimap panel' do
        result = command.execute('map mini')
        expect(result[:success]).to be true
        expect(result[:target_panel]).to eq(:left_minimap)
      end

      it 'includes enabled state in data' do
        result = command.execute('map mini')
        expect(result[:data][:enabled]).to be true
      end

      it 'does not use type :temp' do
        result = command.execute('map mini')
        expect(result[:type]).not_to eq(:temp)
      end
    end

    context 'with invalid map type' do
      it 'returns an error' do
        result = command.execute('map invalid')
        expect(result[:success]).to be false
        expect(result[:message]).to include("Unknown map type")
      end
    end

    context 'with room exits (spatial adjacency)' do
      let!(:exit_room) do
        create(:room,
               name: 'Exit Room', location: location,
               short_description: 'Next room', room_type: 'standard', indoors: false,
               min_x: 0, max_x: 100, min_y: 100, max_y: 200)
      end

      before { room.update(indoors: false) }

      it 'includes exit markers' do
        result = command.execute('map room')
        expect(result[:message]).to include('rect::')
      end
    end

    context 'with other characters in room' do
      let!(:other_instance) do
        create(:character_instance,
               character: create(:character, user: create(:user)),
               current_room: room, x: 25.0, y: 75.0, online: true)
      end

      it 'includes other character markers' do
        result = command.execute('map room')
        expect(result[:message]).to include('fcircle::#22cc22')
      end
    end
  end
end
