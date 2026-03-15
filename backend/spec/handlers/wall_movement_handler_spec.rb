# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WallMovementHandler do
  describe 'module extensions' do
    it 'extends TimedActionHandler' do
      expect(described_class.singleton_class.included_modules).to include(TimedActionHandler)
    end
  end

  describe 'class methods' do
    it 'defines call' do
      expect(described_class).to respond_to(:call)
    end

    describe '.call' do
      it 'accepts a timed_action parameter' do
        method_params = described_class.method(:call).parameters
        expect(method_params).to include([:req, :timed_action])
      end
    end
  end

  describe '.call' do
    let(:room) { create(:room) }
    let(:character) { create(:character) }
    let(:char_instance) do
      create(:character_instance,
             character: character,
             current_room: room,
             x: 50.0,
             y: 50.0,
             z: 0.0,
             movement_state: 'walking')
    end
    let(:action_data) do
      {
        'target_x' => 10.0,
        'target_y' => 5.0,
        'target_z' => 0.0,
        'direction' => 'north'
      }
    end
    let(:timed_action) do
      double('TimedAction',
             parsed_action_data: action_data,
             character_instance: char_instance).tap do |ta|
        allow(described_class).to receive(:store_success)
      end
    end

    before do
      allow(described_class).to receive(:broadcast_personalized_to_room)
      allow(SemoteContinuationHandler).to receive(:call)
    end

    it 'updates character position to target' do
      described_class.call(timed_action)

      char_instance.reload
      expect(char_instance.x).to eq(10.0)
      expect(char_instance.y).to eq(5.0)
      expect(char_instance.z).to eq(0.0)
    end

    it 'sets movement_state to idle' do
      described_class.call(timed_action)

      char_instance.reload
      expect(char_instance.movement_state).to eq('idle')
    end

    it 'broadcasts arrival to room excluding the character' do
      described_class.call(timed_action)

      expect(described_class).to have_received(:broadcast_personalized_to_room).with(
        char_instance.current_room_id,
        "#{char_instance.character.full_name} walks to the northern wall.",
        exclude: [char_instance.id],
        extra_characters: [char_instance]
      )
    end

    it 'stores success result' do
      described_class.call(timed_action)

      expect(described_class).to have_received(:store_success).with(
        timed_action,
        hash_including(
          message: include('northern wall'),
          position: [10.0, 5.0, 0.0]
        )
      )
    end

    it 'calls SemoteContinuationHandler' do
      described_class.call(timed_action)

      expect(SemoteContinuationHandler).to have_received(:call).with(timed_action)
    end

    context 'with different directions' do
      it 'uses correct wall name for south' do
        action_data['direction'] = 'south'

        described_class.call(timed_action)

        expect(described_class).to have_received(:broadcast_personalized_to_room).with(
          char_instance.current_room_id,
          include('southern wall'),
          hash_including(exclude: [char_instance.id])
        )
      end

      it 'uses corner name for northeast' do
        action_data['direction'] = 'northeast'

        described_class.call(timed_action)

        expect(described_class).to have_received(:broadcast_personalized_to_room).with(
          char_instance.current_room_id,
          include('northeast corner'),
          hash_including(exclude: [char_instance.id])
        )
      end

      it 'uses ceiling for up' do
        action_data['direction'] = 'up'

        described_class.call(timed_action)

        expect(described_class).to have_received(:broadcast_personalized_to_room).with(
          char_instance.current_room_id,
          include('ceiling'),
          hash_including(exclude: [char_instance.id])
        )
      end

      it 'uses floor for down' do
        action_data['direction'] = 'down'

        described_class.call(timed_action)

        expect(described_class).to have_received(:broadcast_personalized_to_room).with(
          char_instance.current_room_id,
          include('floor'),
          hash_including(exclude: [char_instance.id])
        )
      end
    end
  end

  describe '.wall_name_for_direction' do
    # Access private class method
    def wall_name_for_direction(direction)
      described_class.send(:wall_name_for_direction, direction)
    end

    it 'returns wall name for cardinal directions' do
      expect(wall_name_for_direction('north')).to eq('northern wall')
      expect(wall_name_for_direction('south')).to eq('southern wall')
      expect(wall_name_for_direction('east')).to eq('eastern wall')
      expect(wall_name_for_direction('west')).to eq('western wall')
    end

    it 'returns corner for ordinal directions' do
      expect(wall_name_for_direction('northeast')).to eq('northeast corner')
      expect(wall_name_for_direction('northwest')).to eq('northwest corner')
      expect(wall_name_for_direction('southeast')).to eq('southeast corner')
      expect(wall_name_for_direction('southwest')).to eq('southwest corner')
    end

    it 'returns ceiling for up' do
      expect(wall_name_for_direction('up')).to eq('ceiling')
    end

    it 'returns floor for down' do
      expect(wall_name_for_direction('down')).to eq('floor')
    end

    it 'returns wall for unrecognized directions' do
      expect(wall_name_for_direction('other')).to eq('other wall')
    end

    it 'handles uppercase directions (preserves original case in output)' do
      # The method compares lowercase but preserves original case in the output
      expect(wall_name_for_direction('NORTH')).to eq('NORTHern wall')
    end

    it 'handles mixed case directions (preserves original case in output)' do
      # The method compares lowercase but preserves original case in the output
      expect(wall_name_for_direction('NorthEast')).to eq('NorthEast corner')
    end
  end
end
