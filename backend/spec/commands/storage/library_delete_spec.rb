# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Storage::LibraryDelete, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Frank') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no name' do
      it 'returns error' do
        result = command.execute('library delete')

        expect(result[:success]).to be false
        expect(result[:error]).to include('What do you want to delete')
      end
    end

    context 'with media library item' do
      let!(:gradient) do
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'gradient',
          mname: 'sunset',
          mtext: '#ff6600,#ff0066'
        )
      end

      it 'deletes the item' do
        result = command.execute('library delete sunset')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Deleted')
        expect(result[:message]).to include('gradient')
        expect(MediaLibrary.find_by_name(character, 'sunset')).to be_nil
      end

      it 'returns delete data in result' do
        result = command.execute('library delete sunset')

        expect(result[:data][:action]).to eq('library_delete')
        expect(result[:data][:deleted_type]).to eq('media')
        expect(result[:data][:media_type]).to eq('gradient')
      end
    end

    context 'with saved location' do
      let!(:saved_loc) do
        SavedLocation.create(
          character_id: character.id,
          room_id: room.id,
          location_name: 'home'
        )
      end

      it 'deletes the location' do
        result = command.execute('library delete home')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Deleted')
        expect(result[:message]).to include('location')
        expect(SavedLocation.find_by_name(character, 'home')).to be_nil
      end

      it 'returns location data in result' do
        result = command.execute('library delete home')

        expect(result[:data][:action]).to eq('library_delete')
        expect(result[:data][:deleted_type]).to eq('location')
      end
    end

    context 'with nonexistent item' do
      it 'returns error' do
        result = command.execute('library delete nonexistent')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Nothing found')
      end
    end

    context 'case sensitivity' do
      let!(:gradient) do
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'gradient',
          mname: 'MyGradient',
          mtext: '#ff0000,#00ff00'
        )
      end

      it 'matches case-insensitively' do
        result = command.execute('library delete mygradient')

        expect(result[:success]).to be true
        expect(MediaLibrary.find_by_name(character, 'MyGradient')).to be_nil
      end
    end

    context 'prioritizes media library over saved locations' do
      let!(:media_item) do
        MediaLibrary.create(
          character_id: character.id,
          mtype: 'pic',
          mname: 'duplicate',
          mtext: 'https://example.com/pic.jpg'
        )
      end

      let!(:saved_loc) do
        SavedLocation.create(
          character_id: character.id,
          room_id: room.id,
          location_name: 'duplicate'
        )
      end

      it 'deletes media library item first' do
        result = command.execute('library delete duplicate')

        expect(result[:success]).to be true
        expect(result[:data][:deleted_type]).to eq('media')
        expect(MediaLibrary.find_by_name(character, 'duplicate')).to be_nil
        expect(SavedLocation.find_by_name(character, 'duplicate')).not_to be_nil
      end
    end
  end

  describe 'aliases' do
    it 'responds to libdelete alias' do
      result = Commands::Base::Registry.find_command('libdelete')
      expect(result[0]).to eq(described_class)
    end

    it 'responds to library del alias' do
      result = Commands::Base::Registry.find_command('library del')
      expect(result[0]).to eq(described_class)
    end
  end
end
