# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::DirectionWalk, type: :command do
  let(:location) { create(:location) }

  # Street room (city_role = 'street')
  let(:street_a) do
    create(:room,
           name: '1st Avenue (south)', short_description: 'A city street', location: location,
           room_type: 'street', city_role: 'street', indoors: false,
           min_x: 100, max_x: 200, min_y: 100, max_y: 200)
  end

  # Adjacent street room to the north
  let(:street_b) do
    create(:room,
           name: '1st Avenue (north)', short_description: 'A city street', location: location,
           room_type: 'street', city_role: 'street', indoors: false,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  # Intersection at the far north
  let(:intersection) do
    create(:room,
           name: 'Main St & 1st Ave', short_description: 'An intersection', location: location,
           room_type: 'intersection', city_role: 'intersection', indoors: false,
           min_x: 100, max_x: 200, min_y: 300, max_y: 400)
  end

  # A non-street standard room
  let(:indoor_room) do
    create(:room,
           name: 'Indoor Room', short_description: 'A standard room', location: location,
           room_type: 'standard', indoors: true,
           min_x: 100, max_x: 200, min_y: 200, max_y: 300)
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: street_a)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'on city streets with adjacent street room' do
      before { street_b }

      it 'starts continuous directional walking with full direction name' do
        result = command.execute('north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('walking north')
      end

      it 'starts walking with short direction alias' do
        result = command.execute('n')

        expect(result[:success]).to be true
        expect(result[:message]).to include('walking north')
      end

      it 'sets movement_direction on the character instance' do
        command.execute('north')

        character_instance.refresh
        expect(character_instance.movement_direction).to eq('north')
        expect(character_instance.movement_state).to eq('moving')
      end

      it 'creates a timed movement action' do
        command.execute('north')

        action = TimedAction.where(
          character_instance_id: character_instance.id,
          action_name: 'movement'
        ).first

        expect(action).not_to be_nil
        expect(action.status).to eq('active')
      end
    end

    context 'with non-street destination' do
      before { indoor_room }

      it 'falls back to single-room movement' do
        result = command.execute('north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('walking')
        # Should NOT set movement_direction (single move, not directional walk)
        character_instance.refresh
        expect(character_instance.movement_direction).to be_nil
      end
    end

    context 'when no exit in direction' do
      it 'returns an error' do
        result = command.execute('south')

        expect(result[:success]).to be false
        expect(result[:error]).to include("can't go south")
      end
    end

    context 'when already moving' do
      before do
        street_b
        character_instance.update(movement_state: 'moving')
      end

      it 'returns an error' do
        result = command.execute('north')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already moving')
      end
    end

    context 'with unknown direction' do
      it 'returns error for invalid command word' do
        # This shouldn't happen in practice since aliases are restricted,
        # but test the fallback
        result = command.execute('direction_walk')

        expect(result[:success]).to be false
      end
    end

    context 'direction aliases' do
      before { street_b }

      %w[north n south s east e west w northeast ne northwest nw southeast se southwest sw].each do |dir|
        it "recognizes '#{dir}' as a valid direction" do
          expect(Commands::Navigation::DirectionWalk::DIRECTION_ALIASES).to have_key(dir)
        end
      end
    end
  end
end
