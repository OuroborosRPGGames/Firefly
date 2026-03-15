# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Customization::Roomtitle, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no args' do
      it 'shows current room title when none set' do
        result = command.execute('roomtitle')

        expect(result[:success]).to be true
        expect(result[:message]).to include("don't have a room title")
        expect(result[:data][:action]).to eq('view_roomtitle')
        expect(result[:data][:roomtitle]).to be_nil
      end

      it 'shows current room title when one is set' do
        character_instance.update(roomtitle: 'looking thoughtful')
        result = command.execute('roomtitle')

        expect(result[:success]).to be true
        expect(result[:message]).to include('looking thoughtful')
        expect(result[:data][:action]).to eq('view_roomtitle')
        expect(result[:data][:roomtitle]).to eq('looking thoughtful')
      end
    end

    context 'setting a room title' do
      it 'sets room title' do
        result = command.execute('roomtitle looking thoughtful')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Room title updated')
        expect(character_instance.reload.roomtitle).to eq('looking thoughtful')
        expect(result[:data][:action]).to eq('set_roomtitle')
        expect(result[:data][:roomtitle]).to eq('looking thoughtful')
      end

      it 'rejects roomtitles over 200 characters' do
        long_title = 'A' * 250
        result = command.execute("roomtitle #{long_title}")

        expect(result[:success]).to be false
        expect(result[:error]).to include('too long')
        expect(result[:error]).to include('200')
      end
    end

    context 'clearing room title' do
      it 'clears room title with clear keyword' do
        character_instance.update(roomtitle: 'looking thoughtful')
        result = command.execute('roomtitle clear')

        expect(result[:success]).to be true
        expect(result[:message]).to include('cleared')
        expect(character_instance.reload.roomtitle).to be_nil
        expect(result[:data][:action]).to eq('clear_roomtitle')
      end
    end
  end
end
