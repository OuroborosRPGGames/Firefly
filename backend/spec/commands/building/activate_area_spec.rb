# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::ActivateLocation, type: :command do
  let(:area) { create(:zone) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let!(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    before do
      allow(character_instance).to receive(:creator_mode?).and_return(true)
      allow(character).to receive(:staff?).and_return(false)
      allow(character).to receive(:admin?).and_return(false)
    end

    context 'with inactive locations' do
      let!(:inactive_location) do
        Location.create(
          name: 'My New Location',
          zone: area,
          location_type: 'outdoor',
          is_active: false,
          created_at: Time.now
        )
      end

      it 'shows menu of inactive locations' do
        result = command.execute('activate area')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:options].length).to eq(1)
        expect(result[:data][:options].first[:label]).to eq('My New Location')
      end

      it 'includes location ids for selection' do
        result = command.execute('activate area')
        expect(result[:data][:location_ids]).to include(inactive_location.id)
      end
    end

    context 'with no inactive locations' do
      it 'shows no locations message' do
        result = command.execute('activate area')
        expect(result[:success]).to be true
        expect(result[:message]).to include('no inactive locations')
        expect(result[:data][:locations]).to eq([])
      end
    end
  end

  describe '#handle_quickmenu_response' do
    subject(:command) { described_class.new(character_instance) }

    let!(:inactive_location) do
      Location.create(
        name: 'My New Location',
        zone: area,
        location_type: 'outdoor',
        is_active: false,
        created_at: Time.now
      )
    end

    it 'activates selected location' do
      context = { location_ids: [inactive_location.id] }
      result = command.send(:handle_quickmenu_response, '1', context)
      expect(result[:success]).to be true
      expect(result[:message]).to include('activated')

      inactive_location.reload
      expect(inactive_location.active?).to be true
    end

    it 'errors on invalid selection' do
      context = { location_ids: [inactive_location.id] }
      result = command.send(:handle_quickmenu_response, '99', context)
      expect(result[:success]).to be false
      expect(result[:error]).to include('Invalid')
    end

    it 'errors when location not found' do
      context = { location_ids: [999999] }
      result = command.send(:handle_quickmenu_response, '1', context)
      expect(result[:success]).to be false
      expect(result[:error]).to include('not found')
    end
  end
end
