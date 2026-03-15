# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Exits, type: :command do
  let(:location) { create(:location) }

  # Base room at center - exits are determined by spatial adjacency
  let(:room) do
    create(:room,
           name: 'Test Room', short_description: 'A room', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # North adjacent room
  let(:north_room) do
    create(:room,
           name: 'North Room', short_description: 'A room to the north', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  # South adjacent room
  let(:south_room) do
    create(:room,
           name: 'South Room', short_description: 'A room to the south', location: location,
           room_type: 'standard', indoors: false,
           min_x: 100, max_x: 200, min_y: 0, max_y: 100)
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no exits' do
      it 'returns success' do
        result = command.execute('exits')
        expect(result[:success]).to be true
      end

      it 'displays no exits message' do
        result = command.execute('exits')
        expect(result[:message]).to eq('There are no visible exits.')
      end

      it 'returns empty exits array in data' do
        result = command.execute('exits')
        expect(result[:data][:exits]).to eq([])
      end
    end

    context 'with visible spatial exits' do
      before { north_room } # Create adjacent room

      it 'returns success' do
        result = command.execute('exits')
        expect(result[:success]).to be true
      end

      it 'displays room name and exits' do
        result = command.execute('exits')
        expect(result[:message]).to include('Test Room')
        expect(result[:message]).to include('Exits:')
        expect(result[:message]).to include('North')
      end

      it 'returns exit data' do
        result = command.execute('exits')
        # Adjacent rooms may show multiple exits due to shared corner edges
        expect(result[:data][:exits]).not_to be_empty
        # Find the north exit specifically
        north_exit = result[:data][:exits].find { |e| e[:direction] == 'north' }
        expect(north_exit).not_to be_nil
        expect(north_exit[:to_room_name]).to eq('North Room')
        # Verify required fields are present
        expect(north_exit).to have_key(:direction)
        expect(north_exit).to have_key(:direction_arrow)
        expect(north_exit).to have_key(:distance)
        expect(north_exit).to have_key(:to_room_id)
        expect(north_exit).to have_key(:exit_type)
        # Distance should be numeric
        expect(north_exit[:distance]).to be_a(Numeric)
      end
    end

    context 'with multiple exits' do
      before do
        north_room
        south_room
      end

      it 'lists all exits' do
        result = command.execute('exits')
        expect(result[:message]).to include('North')
        expect(result[:message]).to include('South')
      end

      it 'returns all exits in data' do
        result = command.execute('exits')
        # Should have at least north and south exits (may have more due to corner adjacencies)
        directions = result[:data][:exits].map { |e| e[:direction] }
        expect(directions).to include('north')
        expect(directions).to include('south')
      end
    end

    context 'with blocked exits (wall)' do
      before do
        north_room
        # Make room indoors with walls blocking all exits
        room.update(indoors: true)
        north_room.update(indoors: true)
        RoomFeature.create(room: room, feature_type: 'wall', direction: 'north')
        RoomFeature.create(room: room, feature_type: 'wall', direction: 'east')
        RoomFeature.create(room: room, feature_type: 'wall', direction: 'west')
      end

      it 'does not show blocked exits' do
        result = command.execute('exits')
        expect(result[:message]).to eq('There are no visible exits.')
      end
    end
  end
end
