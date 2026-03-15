# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Places, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no places' do
      it 'returns success' do
        result = command.execute('places')
        expect(result[:success]).to be true
      end

      it 'displays no places message' do
        result = command.execute('places')
        expect(result[:message]).to eq('There are no notable places here.')
      end

      it 'returns empty places array in data' do
        result = command.execute('places')
        expect(result[:data][:places]).to eq([])
      end
    end

    context 'with visible places' do
      before do
        Place.create(
          room: room,
          name: 'Fireplace',
          description: 'A cozy fireplace',
          invisible: false,
          is_furniture: true,
          capacity: 4
        )
      end

      it 'returns success' do
        result = command.execute('places')
        expect(result[:success]).to be true
      end

      it 'displays places' do
        result = command.execute('places')
        expect(result[:message]).to include('Places:')
        expect(result[:message]).to include('fireplace')
      end

      it 'returns place data' do
        result = command.execute('places')
        expect(result[:data][:places].length).to eq(1)
        expect(result[:data][:places].first[:name]).to eq('Fireplace')
        expect(result[:data][:places].first[:is_furniture]).to be true
      end
    end

    context 'with multiple places' do
      before do
        Place.create(room: room, name: 'Bar', description: 'A long bar', invisible: false, is_furniture: true, capacity: 6)
        Place.create(room: room, name: 'Corner Table', description: 'A corner table', invisible: false, is_furniture: true, capacity: 4)
      end

      it 'lists all places' do
        result = command.execute('places')
        expect(result[:message]).to include('bar')
        expect(result[:message]).to include('corner table')
      end

      it 'returns all places in data' do
        result = command.execute('places')
        expect(result[:data][:places].length).to eq(2)
      end
    end

    context 'with invisible places' do
      before do
        Place.create(room: room, name: 'Secret Alcove', description: 'Hidden', invisible: true, is_furniture: false)
      end

      it 'does not show invisible places' do
        result = command.execute('places')
        expect(result[:message]).to eq('There are no notable places here.')
      end
    end

    context 'with furniture alias' do
      before do
        Place.create(room: room, name: 'Chair', description: 'A chair', invisible: false, is_furniture: true)
      end

      it 'works with furniture alias' do
        result = command.execute('furniture')
        expect(result[:success]).to be true
        expect(result[:message]).to include('chair')
      end
    end

    context 'with spots alias' do
      before do
        Place.create(room: room, name: 'Bench', description: 'A bench', invisible: false, is_furniture: true)
      end

      it 'works with spots alias' do
        result = command.execute('spots')
        expect(result[:success]).to be true
        expect(result[:message]).to include('bench')
      end
    end
  end
end
