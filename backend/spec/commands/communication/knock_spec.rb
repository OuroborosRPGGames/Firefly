# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Knock, type: :command do
  let(:location) { create(:location) }
  # Main room at origin
  let(:room) do
    create(:room,
           name: 'Hallway',
           short_description: 'A hallway',
           location: location,
           room_type: 'standard',
           min_x: 0.0, max_x: 100.0,
           min_y: 0.0, max_y: 100.0)
  end
  # Other room north of main room (shares edge at y=100)
  let(:other_room) do
    create(:room,
           name: 'Bedroom',
           short_description: 'A bedroom',
           location: location,
           room_type: 'standard',
           min_x: 0.0, max_x: 100.0,
           min_y: 100.0, max_y: 200.0)
  end
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no argument' do
      it 'returns error' do
        result = command.execute('knock')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with no exits' do
      # Room with no adjacent rooms
      let(:isolated_room) { create(:room, name: 'Isolated', location: create(:location), room_type: 'standard') }
      let(:isolated_instance) { create(:character_instance, character: character, current_room: isolated_room) }
      let(:isolated_command) { described_class.new(isolated_instance) }

      it 'returns error' do
        result = isolated_command.execute('knock north')
        expect(result[:success]).to be false
        expect(result[:message]).to include('There are no exits to knock on here.')
      end
    end

    context 'with exit to another room' do
      before do
        # Ensure rooms exist for spatial adjacency
        room
        other_room
      end

      it 'returns success' do
        result = command.execute('knock north')
        expect(result[:success]).to be true
      end

      it 'includes knock message' do
        result = command.execute('knock north')
        expect(result[:message]).to include('knocks on the door')
        expect(result[:message]).to include('Bedroom')
      end

      it 'returns knock data' do
        result = command.execute('knock north')
        expect(result[:data][:action]).to eq('knock')
        expect(result[:data][:target_direction]).to eq('north')
        expect(result[:data][:target_room]).to eq('Bedroom')
      end

      it 'works with partial direction' do
        result = command.execute('knock n')
        expect(result[:success]).to be true
      end

      it 'works with room name' do
        result = command.execute('knock bedroom')
        expect(result[:success]).to be true
      end
    end

    context 'with invalid exit' do
      before do
        # Only north exit exists via spatial adjacency
        room
        other_room
      end

      it 'returns error for non-existent direction' do
        result = command.execute('knock south')
        expect(result[:success]).to be false
        expect(result[:message]).to include('No exit like')
      end
    end

    context 'with multiple exits' do
      # Third room south of main room (shares edge at y=0)
      let(:third_room) do
        create(:room,
               name: 'Kitchen',
               short_description: 'A kitchen',
               location: location,
               room_type: 'standard',
               min_x: 0.0, max_x: 100.0,
               min_y: -100.0, max_y: 0.0)
      end

      before do
        # Ensure all rooms exist for spatial adjacency
        room
        other_room
        third_room
      end

      it 'knocks on correct exit' do
        result = command.execute('knock south')
        expect(result[:success]).to be true
        expect(result[:data][:target_room]).to eq('Kitchen')
      end
    end
  end
end
