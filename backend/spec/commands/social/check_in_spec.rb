# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Social::CheckIn, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let!(:character_instance) { create(:character_instance, character: character, current_room: room, locatability: 'yes') }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'alias wherevis' do
      it 'shows locatability quickmenu when using wherevis' do
        result = command.execute('wherevis')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:prompt]).to include('locatability')
      end
    end

    context 'with no argument' do
      it 'shows locatability quickmenu' do
        result = command.execute('checkin')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:prompt]).to include('locatability')
      end

      it 'returns options for yes, favorites, and no' do
        result = command.execute('checkin')
        options = result[:data][:options]
        keys = options.map { |o| o[:key] }
        expect(keys).to include('yes', 'favorites', 'no')
      end
    end

    context 'with direct locatability argument' do
      it 'sets locatability to yes' do
        result = command.execute('checkin yes')
        expect(result[:success]).to be true
        expect(result[:message]).to include('visible to anyone')
        character_instance.reload
        expect(character_instance.locatability).to eq('yes')
      end

      it 'sets locatability to no' do
        result = command.execute('checkin no')
        expect(result[:success]).to be true
        expect(result[:message]).to include('hidden from where')
        character_instance.reload
        expect(character_instance.locatability).to eq('no')
      end

      it 'sets locatability to favorites' do
        result = command.execute('checkin favorites')
        expect(result[:success]).to be true
        expect(result[:message]).to include('visible only to favorites')
        character_instance.reload
        expect(character_instance.locatability).to eq('favorites')
      end
    end

    context 'error cases' do
      it 'errors on invalid locatability value' do
        result = command.execute('checkin invalid')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid')
      end
    end
  end
end
