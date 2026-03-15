# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CityJourneyHandler do
  # Use a mock timed_action to avoid database dependencies
  let(:journey_id) { 123 }
  let(:mock_timed_action) do
    instance_double(
      TimedAction,
      parsed_action_data: { journey_id: journey_id },
      update: true
    )
  end

  describe '.call' do
    it 'advances the journey via VehicleTravelService' do
      expect(VehicleTravelService).to receive(:advance_journey).with(journey_id)

      described_class.call(mock_timed_action)
    end

    it 'stores success in result_data' do
      allow(VehicleTravelService).to receive(:advance_journey)

      expect(mock_timed_action).to receive(:update) do |args|
        result = JSON.parse(args[:result_data])
        expect(result['success']).to eq(true)
        expect(result['journey_id']).to eq(journey_id)
      end

      described_class.call(mock_timed_action)
    end

    context 'when journey_id is missing from action data' do
      let(:mock_timed_action) do
        instance_double(
          TimedAction,
          parsed_action_data: {},
          update: true
        )
      end

      it 'does not call advance_journey' do
        expect(VehicleTravelService).not_to receive(:advance_journey)

        described_class.call(mock_timed_action)
      end

      it 'stores error in result_data' do
        expect(mock_timed_action).to receive(:update) do |args|
          result = JSON.parse(args[:result_data])
          expect(result['success']).to eq(false)
          expect(result['error']).to include('journey_id')
        end

        described_class.call(mock_timed_action)
      end
    end

    context 'when VehicleTravelService raises an error' do
      before do
        allow(VehicleTravelService).to receive(:advance_journey)
          .and_raise(StandardError, 'Journey not found')
      end

      it 'stores error in result_data' do
        expect(mock_timed_action).to receive(:update) do |args|
          result = JSON.parse(args[:result_data])
          expect(result['success']).to eq(false)
          expect(result['error']).to include('Journey not found')
        end

        described_class.call(mock_timed_action)
      end
    end
  end
end
