# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Consumption::Drink do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without an item name' do
      it 'returns an error' do
        result = subject.execute('drink')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Drink what")
      end
    end

    context 'when already drinking' do
      let(:drink_pattern) { create_test_pattern(consume_type: 'drink') }
      let!(:drink_item) { create_test_item(name: 'Water', pattern: drink_pattern, character_instance: character_instance) }

      before do
        character_instance.start_drinking!(drink_item)
      end

      it 'returns an error' do
        result = subject.execute('drink coffee')
        expect(result[:success]).to be false
        expect(result[:error]).to include("already drinking")
      end
    end

    context 'with a valid drink item in inventory' do
      let(:drink_pattern) { create_test_pattern(consume_type: 'drink', taste: 'Refreshing!', consume_time: 3) }
      let!(:drink_item) { create_test_item(name: 'Water', pattern: drink_pattern, character_instance: character_instance) }

      it 'starts drinking the item' do
        result = subject.execute('drink Water')
        expect(result[:success]).to be true
        expect(result[:message]).to include("start drinking")
        expect(result[:message]).to include("Water")
        expect(result[:message]).to include("Refreshing!")
      end

      it 'sets drinking state on character' do
        subject.execute('drink Water')
        character_instance.reload
        expect(character_instance.drinking?).to be true
        expect(character_instance.drinking_id).to eq(drink_item.id)
      end
    end
  end
end
