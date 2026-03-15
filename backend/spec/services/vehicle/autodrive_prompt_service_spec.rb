# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutodrivePromptService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:reality) { create(:reality) }

  # Streets are spatially adjacent: street1 -> street2 -> destination (north)
  # street1: y=0-100, street2: y=100-200, destination: y=200-300
  # Streets must be outdoors (indoors: false) for spatial passability
  let(:street1) { create(:room, room_type: 'street', name: 'Start Street', location: location, min_y: 0.0, max_y: 100.0, indoors: false) }
  let(:street2) { create(:room, room_type: 'street', name: 'Mid Street', location: location, min_y: 100.0, max_y: 200.0, indoors: false) }
  let(:destination) { create(:room, room_type: 'street', name: 'End Street', location: location, min_y: 200.0, max_y: 300.0, indoors: false) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: street1,
           reality: reality)
  end

  describe '.should_prompt?' do
    context 'with vehicle in current room' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street1, parked: true) }

      it 'returns true regardless of distance' do
        result = described_class.should_prompt?(character_instance, destination)
        expect(result).to be true
      end
    end

    context 'without vehicle nearby' do
      let(:far_room) { create(:room, location: location) }
      let!(:vehicle) { create(:vehicle, owner: character, current_room: far_room, parked: true) }

      it 'returns true if distance exceeds threshold' do
        allow(VehicleTravelService).to receive(:calculate_route_distance).and_return(1000)
        allow(TaxiService).to receive(:available?).and_return(true)

        result = described_class.should_prompt?(character_instance, destination)
        expect(result).to be true
      end

      it 'returns false if distance is short' do
        allow(VehicleTravelService).to receive(:calculate_route_distance).and_return(100)

        result = described_class.should_prompt?(character_instance, destination)
        expect(result).to be false
      end
    end

    context 'without any vehicle and no taxi' do
      it 'returns false when no transportation available' do
        allow(TaxiService).to receive(:available?).and_return(false)
        allow(VehicleTravelService).to receive(:calculate_route_distance).and_return(1000)

        result = described_class.should_prompt?(character_instance, destination)
        expect(result).to be false
      end
    end
  end

  describe '.build_options' do
    before do
      # Stub era/taxi service to return consistent values
      allow(TaxiService).to receive(:available?).and_return(true)
      allow(TaxiService).to receive(:taxi_name).and_return('ride')
      allow(VehicleTravelService).to receive(:calculate_route_distance).and_return(500)
      allow(VehicleTravelService).to receive(:estimate_travel_time).and_return(30)
      allow(VehicleTravelService).to receive(:estimate_walking_time).and_return(120)
    end

    context 'with vehicle in current room' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street1, parked: true, name: 'Blue Sedan') }

      it 'includes drive option when vehicle is here' do
        options = described_class.build_options(character_instance, destination)

        drive_option = options.find { |o| o[:action] == 'drive' }
        expect(drive_option).not_to be_nil
        expect(drive_option[:label]).to include('Blue Sedan')
      end

      it 'adds vehicle reminder note to non-drive options' do
        options = described_class.build_options(character_instance, destination)

        walk_option = options.find { |o| o[:action] == 'walk' }
        expect(walk_option[:note]).to include('Blue Sedan')
        expect(walk_option[:note]).to include('parked')
      end
    end

    context 'with taxi available' do
      it 'includes taxi option when available' do
        options = described_class.build_options(character_instance, destination)

        taxi_option = options.find { |o| o[:action] == 'taxi' }
        expect(taxi_option).not_to be_nil
        expect(taxi_option[:label]).to include('ride')
      end
    end

    context 'with no taxi available' do
      before do
        allow(TaxiService).to receive(:available?).and_return(false)
      end

      it 'excludes taxi option when not available' do
        options = described_class.build_options(character_instance, destination)

        taxi_option = options.find { |o| o[:action] == 'taxi' }
        expect(taxi_option).to be_nil
      end
    end

    it 'always includes walk option' do
      options = described_class.build_options(character_instance, destination)

      walk_option = options.find { |o| o[:action] == 'walk' }
      expect(walk_option).not_to be_nil
      expect(walk_option[:label]).to include('Walk')
    end

    it 'formats time estimates correctly' do
      allow(VehicleTravelService).to receive(:estimate_walking_time).and_return(90)  # 1.5 minutes
      allow(VehicleTravelService).to receive(:estimate_travel_time).and_return(15)   # 15 seconds

      options = described_class.build_options(character_instance, destination)

      walk_option = options.find { |o| o[:action] == 'walk' }
      expect(walk_option[:label]).to include('2min')  # 90 seconds rounds up to 2 min
    end

    it 'includes time estimates for each option' do
      options = described_class.build_options(character_instance, destination)

      options.each do |opt|
        expect(opt[:label]).to match(/~\d+/)
      end
    end
  end
end
