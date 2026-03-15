# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Storage::SaveLocation, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world, name: 'Downtown') }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Coffee Shop') }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Charlie') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid name' do
      it 'saves the location' do
        result = command.execute('save location as cafe')

        expect(result[:success]).to be true
        expect(result[:message]).to include('saved')
        expect(result[:message]).to include('cafe')
        expect(SavedLocation.find_by_name(character, 'cafe')).not_to be_nil
      end

      it 'returns location data in result' do
        result = command.execute('save location as work')

        expect(result[:data][:action]).to eq('save_location')
        expect(result[:data][:name]).to eq('work')
        expect(result[:data][:room_id]).to eq(room.id)
      end

      it 'supports just name without "as"' do
        result = command.execute('save location cafe')

        expect(result[:success]).to be true
        expect(SavedLocation.find_by_name(character, 'cafe')).not_to be_nil
      end
    end

    context 'with no name provided' do
      it 'returns error' do
        result = command.execute('save location')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Usage')
      end
    end

    context 'with duplicate name' do
      before do
        SavedLocation.create(
          character_id: character.id,
          room_id: room.id,
          location_name: 'existing'
        )
      end

      it 'returns error' do
        result = command.execute('save location as existing')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have')
      end
    end

    context 'case sensitivity' do
      before do
        SavedLocation.create(
          character_id: character.id,
          room_id: room.id,
          location_name: 'MyPlace'
        )
      end

      it 'treats names as case-insensitive' do
        result = command.execute('save location as myplace')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have')
      end
    end
  end

  describe 'aliases' do
    it 'responds to saveloc alias' do
      result = Commands::Base::Registry.find_command('saveloc')
      expect(result[0]).to eq(described_class)
    end

    it 'responds to bookmark alias' do
      result = Commands::Base::Registry.find_command('bookmark')
      expect(result[0]).to eq(described_class)
    end
  end
end
