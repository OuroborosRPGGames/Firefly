# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Think, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, stance: 'standing') }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'basic thinking' do
      it 'accepts a thought' do
        result = command.execute('think I wonder what is happening')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:silent)
        expect(result[:data][:thought]).to eq('I wonder what is happening')
      end

      it 'returns error without thought' do
        result = command.execute('think')
        expect(result[:success]).to be false
        expect(result[:message]).to include('thinking')
      end
    end

    context 'different verb aliases' do
      it 'uses "thinks" for think command' do
        result = command.execute('think deep thoughts')
        expect(result[:data][:verb]).to eq('thinks')
      end

      it 'uses "hopes" for hope command' do
        result = command.execute('hope for the best')
        expect(result[:data][:verb]).to eq('hopes')
      end

      it 'uses "ponders" for ponder command' do
        result = command.execute('ponder the meaning of life')
        expect(result[:data][:verb]).to eq('ponders')
      end

      it 'uses "wonders" for wonder command' do
        result = command.execute('wonder about the stars')
        expect(result[:data][:verb]).to eq('wonders')
      end

      it 'uses "worries" for worry command' do
        result = command.execute('worry about tomorrow')
        expect(result[:data][:verb]).to eq('worries')
      end

      it 'uses "wishes" for wish command' do
        result = command.execute('wish for better days')
        expect(result[:data][:verb]).to eq('wishes')
      end

      it 'uses "feels" for feel command' do
        result = command.execute('feel uncertain')
        expect(result[:data][:verb]).to eq('feels')
      end
    end

    context 'with observers' do
      let(:user2) { create(:user) }
      let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
      let!(:bob_instance) { create(:character_instance, character: bob_character, current_room: room, reality: reality, stance: 'standing') }

      it 'succeeds with an observer present' do
        bob_instance.start_observing!(character_instance)
        result = command.execute('think this is a secret')
        expect(result[:success]).to be true
      end
    end

    context 'with mind readers' do
      let(:user2) { create(:user) }
      let(:bob_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }
      let!(:bob_instance) { create(:character_instance, character: bob_character, current_room: room, reality: reality, stance: 'standing') }

      it 'succeeds with a mind reader present' do
        bob_instance.start_reading_mind!(character_instance)
        result = command.execute('think about my deepest secrets')
        expect(result[:success]).to be true
      end
    end
  end
end
