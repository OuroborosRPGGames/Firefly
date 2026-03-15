# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Vehicles::Drive, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  # Streets are spatially adjacent: street -> destination (north)
  # street: y=0-100, destination: y=100-200
  # Streets must be outdoors (indoors: false) for spatial passability
  let(:street) { create(:room, location: location, room_type: 'street', name: 'Oak Street', min_y: 0.0, max_y: 100.0, indoors: false) }
  let(:destination) { create(:room, location: location, room_type: 'street', name: 'Pine Ave', min_y: 100.0, max_y: 200.0, indoors: false) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: street, reality: reality, online: true) }

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'drive' : "drive #{args}"
    command.execute(input)
  end

  describe 'command registration' do
    it 'is registered with the correct name' do
      expect(described_class.command_name).to eq('drive')
    end

    it 'has help text' do
      expect(described_class.help_text).not_to be_nil
    end

    it 'is in the navigation category' do
      expect(described_class.category).to eq(:navigation)
    end
  end

  describe '#execute' do
    context 'with vehicle in current room' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street, parked: true, name: 'Blue Sedan') }

      before do
        # Ensure destination room exists before tests run
        destination
      end

      it 'starts driving to destination' do
        result = execute_command('to Pine Ave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Blue Sedan')
        expect(result[:message]).to include('Pine Ave')
      end

      it 'creates a CityJourney' do
        expect {
          execute_command('to Pine Ave')
        }.to change { CityJourney.count }.by(1)

        journey = CityJourney.order(:id).last
        expect(journey).not_to be_nil
        expect(journey.driver_id).to eq(character_instance.id)
        expect(journey.vehicle_id).to eq(vehicle.id)
        expect(journey.destination_room_id).to eq(destination.id)
      end

      it 'returns journey data in result' do
        result = execute_command('to Pine Ave')

        expect(result[:data]).to include(:journey_id)
        expect(result[:data][:destination]).to eq('Pine Ave')
      end

      it 'handles destination without "to" prefix' do
        result = execute_command('Pine Ave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Pine Ave')
      end
    end

    context 'without vehicle' do
      it 'returns error about not having a vehicle' do
        result = execute_command('to Pine Ave')

        expect(result[:success]).to be false
        # HTML-escaped apostrophe
        expect(result[:message]).to include('have a vehicle')
      end
    end

    context 'with vehicle elsewhere' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: destination, parked: true, name: 'Blue Sedan') }

      it 'returns error about vehicle location' do
        result = execute_command('to Pine Ave')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not here')
      end

      it 'tells the player where their vehicle is' do
        result = execute_command('to Pine Ave')

        expect(result[:message]).to include('Pine Ave')
      end
    end

    context 'with no destination specified' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street, parked: true, name: 'Blue Sedan') }

      it 'returns error asking for destination' do
        result = execute_command('')

        expect(result[:success]).to be false
        expect(result[:message]).to match(/where/i)
      end
    end

    context 'with unknown destination' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street, parked: true, name: 'Blue Sedan') }

      it 'returns error about unknown location' do
        result = execute_command('to Nowhere Land')

        expect(result[:success]).to be false
        # HTML-escaped apostrophe
        expect(result[:message]).to include('know where')
      end
    end

    context 'when already in a vehicle' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street, parked: true, name: 'Blue Sedan') }

      before do
        # Ensure destination room exists
        destination
        # Board the vehicle
        character_instance.update(current_vehicle_id: vehicle.id)
      end

      it 'uses the vehicle they are in' do
        result = execute_command('to Pine Ave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Blue Sedan')
      end
    end

    context 'with unreachable destination' do
      let!(:vehicle) { create(:vehicle, owner: character, current_room: street, parked: true, name: 'Blue Sedan') }
      let(:isolated_room) { create(:room, location: location, room_type: 'street', name: 'Isolated Street') }

      it 'returns error about no route or unknown destination' do
        result = execute_command('to Isolated Street')

        expect(result[:success]).to be false
        # May return "Can't find a route" or "don't know where" depending on pathfinding
        expect(result[:message]).to match(/find|know where/i)
      end
    end
  end
end
