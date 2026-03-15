# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DisambiguationHandler do
  let(:location) { create(:location) }

  # Room A and Room B are spatially adjacent (room B is north of room A)
  let(:room_a) do
    create(:room,
      location: location,
      name: 'Room A',
      short_description: 'Start',
      min_x: 0.0, max_x: 100.0,
      min_y: 0.0, max_y: 100.0
    )
  end

  let(:room_b) do
    create(:room,
      location: location,
      name: 'Room B',
      short_description: 'North room',
      min_x: 0.0, max_x: 100.0,
      min_y: 100.0, max_y: 200.0  # North of room_a (higher Y)
    )
  end

  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room_a
    )
  end

  describe '.process_response' do
    context 'with exit type disambiguation' do
      let(:interaction_data) do
        {
          context: {
            type: 'exit',
            adverb: 'walk'
          }
        }
      end

      it 'processes valid exit selection' do
        # Ensure rooms are created for spatial adjacency
        room_a
        room_b

        mock_result = ResultHandler::Result.new(success: true, message: 'Walking north')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        # With spatial adjacency, selected_key is the direction itself
        result = described_class.process_response(
          character_instance,
          interaction_data,
          'north'
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'north',
          adverb: 'walk'
        )
      end

      it 'passes any direction to MovementService (validation happens there)' do
        mock_result = ResultHandler::Result.new(success: false, message: 'No exit in that direction')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          'invalid_direction'
        )

        # DisambiguationHandler passes direction to MovementService which validates
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'invalid_direction',
          adverb: 'walk'
        )
      end
    end

    context 'with character type disambiguation' do
      let(:user2) { create(:user) }
      let(:other_character) { create(:character, forename: 'Other', surname: 'Person', user: user2) }
      let!(:other_instance) do
        create(:character_instance,
          character: other_character,
          reality: reality,
          current_room: room_a
        )
      end

      let(:interaction_data) do
        {
          context: {
            type: 'character',
            adverb: 'walk'
          }
        }
      end

      it 'processes valid character selection' do
        mock_result = ResultHandler::Result.new(success: true, message: 'Walking to Other')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          other_instance.id.to_s
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'Other Person',
          adverb: 'walk'
        )
      end

      it 'returns error for invalid character id' do
        result = described_class.process_response(
          character_instance,
          interaction_data,
          '999999'
        )

        expect(result.success).to be false
        expect(result.message).to include('Character not found')
      end
    end

    context 'with room type disambiguation' do
      let(:interaction_data) do
        {
          context: {
            type: 'room',
            adverb: 'walk'
          }
        }
      end

      it 'processes valid room selection' do
        mock_result = ResultHandler::Result.new(success: true, message: 'Walking to Room B')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          room_b.id.to_s
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'Room B',
          adverb: 'walk'
        )
      end

      it 'returns error for invalid room id' do
        result = described_class.process_response(
          character_instance,
          interaction_data,
          '999999'
        )

        expect(result.success).to be false
        expect(result.message).to include('Room not found')
      end
    end

    context 'with furniture type disambiguation' do
      let(:pattern) do
        uot = UnifiedObjectType.create(
          name: 'Furniture',
          category: 'Accessory'
        )
        Pattern.create(
          description: 'A comfortable chair',
          unified_object_type: uot,
          price: 50
        )
      end

      let!(:furniture) do
        Item.create(
          name: 'Chair',
          pattern: pattern,
          room_id: room_a.id
        )
      end

      let(:interaction_data) do
        {
          context: {
            type: 'furniture',
            adverb: 'walk'
          }
        }
      end

      it 'processes valid furniture selection' do
        mock_result = ResultHandler::Result.new(success: true, message: 'Approaching the Chair')
        allow(MovementService).to receive(:approach_furniture).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          furniture.id.to_s
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:approach_furniture).with(
          character_instance,
          furniture,
          'walk'
        )
      end

      it 'returns error for invalid furniture id' do
        result = described_class.process_response(
          character_instance,
          interaction_data,
          '999999'
        )

        expect(result.success).to be false
        expect(result.message).to include('Object not found')
      end
    end

    context 'with unknown type' do
      let(:interaction_data) do
        {
          context: {
            type: 'unknown_type',
            adverb: 'walk'
          }
        }
      end

      it 'returns error for unknown disambiguation type' do
        result = described_class.process_response(
          character_instance,
          interaction_data,
          '1'
        )

        expect(result.success).to be false
        expect(result.message).to include('Unknown disambiguation type')
      end
    end

    context 'with string keys in context' do
      let(:interaction_data) do
        {
          'context' => {
            'type' => 'exit',
            'adverb' => 'run'
          }
        }
      end

      it 'handles string keys correctly' do
        mock_result = ResultHandler::Result.new(success: true, message: 'Running north')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          'north'
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'north',
          adverb: 'run'
        )
      end
    end

    context 'with missing adverb' do
      let(:interaction_data) do
        {
          context: {
            type: 'exit'
          }
        }
      end

      it 'defaults to walk adverb' do
        mock_result = ResultHandler::Result.new(success: true, message: 'Walking north')
        allow(MovementService).to receive(:start_movement).and_return(mock_result)

        result = described_class.process_response(
          character_instance,
          interaction_data,
          'north'
        )

        expect(result.success).to be true
        expect(MovementService).to have_received(:start_movement).with(
          character_instance,
          target: 'north',
          adverb: 'walk'
        )
      end
    end
  end
end
