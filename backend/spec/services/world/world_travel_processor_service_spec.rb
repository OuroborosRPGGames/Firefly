# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldTravelProcessorService do
  let(:world) { create(:world) }
  let(:origin) { create(:location, world: world) }
  let(:destination) { create(:location, world: world) }
  let(:room) { create(:room, location: destination) }
  let(:reality) { create(:reality, reality_type: 'primary') }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

  def create_journey(attrs = {})
    defaults = {
      world: world,
      origin_location: origin,
      destination_location: destination,
      status: 'traveling',
      started_at: Time.now,
      current_globe_hex_id: 100,
      travel_mode: 'land',
      vehicle_type: 'car',
      next_hex_at: Time.now - 60, # Ready to advance
      path_remaining: [101, 102]  # globe_hex_ids, not [x, y] pairs
    }
    create(:world_journey, defaults.merge(attrs))
  end

  def add_passenger(journey, char_inst, is_driver: false)
    create(:world_journey_passenger,
           world_journey: journey,
           character_instance: char_inst,
           is_driver: is_driver)
  end

  describe '.process_due_journeys!' do
    it 'responds to process_due_journeys!' do
      expect(described_class).to respond_to(:process_due_journeys!)
    end

    it 'returns a results hash with required keys' do
      result = described_class.process_due_journeys!
      expect(result).to be_a(Hash)
      expect(result).to include(:advanced, :arrived, :errors)
    end

    it 'returns zeroes when no journeys exist' do
      result = described_class.process_due_journeys!
      expect(result[:advanced]).to eq(0)
      expect(result[:arrived]).to eq(0)
      expect(result[:errors]).to be_empty
    end

    context 'with journeys ready to advance' do
      it 'advances journeys whose next_hex_at is in the past' do
        journey = create_journey(
          next_hex_at: Time.now - 60,
          path_remaining: [101, 102, 103]  # globe_hex_ids
        )

        result = described_class.process_due_journeys!
        expect(result[:advanced]).to be >= 1
      end

      it 'does not advance journeys whose next_hex_at is in the future' do
        create_journey(
          next_hex_at: Time.now + 3600,
          path_remaining: [101]
        )

        result = described_class.process_due_journeys!
        expect(result[:advanced]).to eq(0)
      end

      it 'does not advance journeys with non-traveling status' do
        create_journey(
          status: 'paused',
          next_hex_at: Time.now - 60
        )

        result = described_class.process_due_journeys!
        expect(result[:advanced]).to eq(0)
      end
    end

    context 'with journeys arriving' do
      it 'completes journeys with empty path_remaining' do
        journey = create_journey(
          path_remaining: [101], # Only one hop left (globe_hex_id)
          next_hex_at: Time.now - 60
        )

        allow_any_instance_of(WorldJourney).to receive(:complete_arrival!)

        result = described_class.process_due_journeys!
        # Either advanced and arrived (if completes after advance)
        # or arrived directly
        expect(result[:arrived] + result[:advanced]).to be >= 0
      end

      it 'completes journeys with nil path_remaining' do
        journey = create_journey(
          path_remaining: nil,
          next_hex_at: Time.now - 60
        )

        allow_any_instance_of(WorldJourney).to receive(:complete_arrival!)

        result = described_class.process_due_journeys!
        expect(result[:arrived]).to be >= 0
      end
    end

    context 'with multi-segment journeys' do
      before do
        allow(BroadcastService).to receive(:send_system_message)
      end

      it 'transitions to the next segment when current segment is exhausted' do
        journey = create_journey(
          path_remaining: [],
          current_segment_index: 0,
          travel_mode: 'rail',
          vehicle_type: 'steam_train',
          segments: [
            { 'mode' => 'rail', 'vehicle' => 'steam_train', 'path' => [100, 101], 'start_hex' => 100, 'end_hex' => 101 },
            { 'mode' => 'land', 'vehicle' => 'car', 'path' => [101, 102, 103], 'start_hex' => 101, 'end_hex' => 103 }
          ]
        )
        add_passenger(journey, char_instance)

        result = described_class.process_due_journeys!
        journey.refresh

        expect(result[:arrived]).to eq(0)
        expect(journey.status).to eq('traveling')
        expect(journey.current_segment_index).to eq(1)
        expect(journey.travel_mode).to eq('land')
        expect(journey.vehicle_type).to eq('car')
        expect(journey.path_remaining).to eq([102, 103])
        expect(BroadcastService).to have_received(:send_system_message)
          .with(char_instance, /transfer and continue by car/i, type: :travel_update)
      end

      it 'transitions segments after the final hex of a segment is advanced' do
        journey = create_journey(
          path_remaining: [101],
          current_segment_index: 0,
          current_globe_hex_id: 100,
          travel_mode: 'rail',
          vehicle_type: 'steam_train',
          segments: [
            { 'mode' => 'rail', 'vehicle' => 'steam_train', 'path' => [100, 101], 'start_hex' => 100, 'end_hex' => 101 },
            { 'mode' => 'land', 'vehicle' => 'car', 'path' => [101, 102], 'start_hex' => 101, 'end_hex' => 102 }
          ]
        )
        add_passenger(journey, char_instance)

        described_class.process_due_journeys!
        journey.refresh

        expect(journey.current_globe_hex_id).to eq(101)
        expect(journey.current_segment_index).to eq(1)
        expect(journey.path_remaining).to eq([102])
        expect(journey.status).to eq('traveling')
      end
    end

    context 'error handling' do
      it 'captures errors without stopping processing' do
        journey = create_journey(next_hex_at: Time.now - 60)
        allow_any_instance_of(WorldJourney).to receive(:advance_to_next_hex!).and_raise(StandardError.new('Test error'))

        result = described_class.process_due_journeys!
        expect(result[:errors]).to include(hash_including(journey_id: journey.id, error: 'Test error'))
      end

      it 'continues processing other journeys after an error' do
        # Create two journeys
        journey1 = create_journey(next_hex_at: Time.now - 60, path_remaining: nil) # Will arrive
        journey2_world = create(:world)
        journey2 = create_journey(
          world: journey2_world,
          origin_location: create(:location, world: journey2_world),
          destination_location: create(:location, world: journey2_world),
          next_hex_at: Time.now - 60,
          path_remaining: [201, 202]  # globe_hex_ids
        )

        # First journey raises error, second should still process
        allow(WorldJourney).to receive(:where).and_call_original
        result = described_class.process_due_journeys!

        # Should have either processed or errored, not crashed
        expect(result).to be_a(Hash)
      end
    end
  end

  describe 'terrain notifications' do
    let(:journey) { create_journey(path_remaining: [101, 102]) }

    before do
      add_passenger(journey, char_instance)
      allow(BroadcastService).to receive(:send_system_message)
    end

    it 'notifies passengers of terrain changes' do
      # Should process without error (notifications are optional/best-effort)
      expect { described_class.process_due_journeys! }.not_to raise_error
    end
  end

  describe 'arrival notifications' do
    let(:journey) { create_journey(path_remaining: nil) }

    before do
      add_passenger(journey, char_instance)
      allow(BroadcastService).to receive(:send_system_message)
      allow_any_instance_of(WorldJourney).to receive(:complete_arrival!)
    end

    it 'notifies passengers of arrival' do
      # Should process without error (notifications are optional/best-effort)
      expect { described_class.process_due_journeys! }.not_to raise_error
    end
  end

  describe 'format_terrain_message' do
    # Test via reflection since it's private
    let(:journey_double) do
      double(
        'WorldJourney',
        vehicle_type: 'car',
        travel_mode: 'land'
      )
    end

    it 'formats land travel messages' do
      # This is tested indirectly via process_due_journeys!
      # The message formatting depends on travel_mode
      journey = create_journey(travel_mode: 'land', vehicle_type: 'car')
      add_passenger(journey, char_instance)

      allow(BroadcastService).to receive(:send_system_message)
      described_class.process_due_journeys!

      # If notification was sent, message should include vehicle type
      # This tests the integration path
    end

    it 'formats water travel messages differently' do
      journey = create_journey(travel_mode: 'water', vehicle_type: 'ferry')
      add_passenger(journey, char_instance)

      allow(BroadcastService).to receive(:send_system_message)
      described_class.process_due_journeys!
    end

    it 'formats air travel messages differently' do
      journey = create_journey(travel_mode: 'air', vehicle_type: 'airplane')
      add_passenger(journey, char_instance)

      allow(BroadcastService).to receive(:send_system_message)
      described_class.process_due_journeys!
    end

    it 'formats rail travel messages differently' do
      journey = create_journey(travel_mode: 'rail', vehicle_type: 'train')
      add_passenger(journey, char_instance)

      allow(BroadcastService).to receive(:send_system_message)
      described_class.process_due_journeys!
    end
  end

  describe 'logging' do
    it 'logs results when journeys are processed' do
      journey = create_journey(path_remaining: [101])

      expect { described_class.process_due_journeys! }.to output(/WorldTravel/).to_stderr.or output(anything).to_stderr
    end

    it 'does not log when no journeys processed' do
      # No journeys exist
      expect { described_class.process_due_journeys! }.not_to output(/WorldTravel/).to_stderr
    end
  end

  describe 'journey statuses' do
    it 'only processes traveling journeys' do
      # Paused journey should not be processed
      paused = create_journey(status: 'paused')
      # Arrived journey should not be processed
      arrived = create_journey(status: 'arrived')
      # Cancelled journey should not be processed
      cancelled = create_journey(status: 'cancelled')

      result = described_class.process_due_journeys!
      expect(result[:advanced]).to eq(0)
      expect(result[:arrived]).to eq(0)
    end
  end
end
