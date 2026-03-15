# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MovementHandler do
  let(:location) { create(:location) }

  # Room A and Room B are spatially adjacent (room B is north of room A)
  let(:room_a) do
    create(:room,
      location: location,
      name: 'Room A',
      short_description: 'Start',
      indoors: false,
      min_x: 0.0, max_x: 100.0,
      min_y: 0.0, max_y: 100.0
    )
  end

  let(:room_b) do
    create(:room,
      location: location,
      name: 'Room B',
      short_description: 'Destination',
      indoors: false,
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
      current_room: room_a,
      movement_state: 'moving'
    )
  end

  # With spatial adjacency, timed actions store destination_room_id and direction
  let(:timed_action) do
    TimedAction.start_delayed(
      character_instance,
      'movement',
      1000,
      'MovementHandler',
      { destination_room_id: room_b.id, direction: 'north' }
    )
  end

  describe '.call' do
    context 'with valid exit' do
      it 'completes room transition' do
        described_class.call(timed_action)

        expect(character_instance.reload.current_room_id).to eq(room_b.id)
      end

      it 'stores success in result_data' do
        described_class.call(timed_action)

        action = timed_action.reload
        result = action.parsed_result_data
        expect(result[:success]).to eq(true)
        expect(result[:moved_to]).to eq(room_b.id)
        expect(result[:moved_from]).to eq(room_a.id)
      end
    end

    context 'when destination room no longer exists' do
      before { room_b.delete }

      it 'stores error in result_data' do
        described_class.call(timed_action)

        action = timed_action.reload
        result = action.parsed_result_data
        expect(result[:success]).to eq(false)
        expect(result[:error]).to include('no longer exists')
      end
    end

    context 'when passage is blocked' do
      before do
        # Stub RoomPassabilityService to indicate the passage is blocked
        allow(RoomPassabilityService).to receive(:can_pass?).and_return(false)
      end

      it 'stores error and resets movement state' do
        described_class.call(timed_action)

        action = timed_action.reload
        result = action.parsed_result_data
        expect(result[:success]).to eq(false)
        expect(result[:error]).to include('blocked')
        expect(character_instance.reload.movement_state).to eq('idle')
      end
    end

    context 'when destination has active fight' do
      let!(:active_fight) do
        Fight.create(
          room_id: room_b.id,
          status: 'input',
          round_number: 1,
          started_at: Time.now
        )
      end

      it 'prevents entry and resets movement state' do
        # FightEntryDelayService.can_enter? should return false for new entries
        allow(FightEntryDelayService).to receive(:can_enter?).and_return(false)
        allow(FightEntryDelayService).to receive(:rounds_until_entry).and_return(3)

        described_class.call(timed_action)

        action = timed_action.reload
        result = action.parsed_result_data
        expect(result[:success]).to eq(false)
        expect(result[:error]).to include('Fight in progress')
        expect(character_instance.reload.movement_state).to eq('idle')
      end

      it 'allows entry when waiting period completed' do
        allow(FightEntryDelayService).to receive(:can_enter?).and_return(true)

        described_class.call(timed_action)

        expect(character_instance.reload.current_room_id).to eq(room_b.id)
      end
    end
  end
end
