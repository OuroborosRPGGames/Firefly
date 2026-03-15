# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Consumption::Eat do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without an item name' do
      it 'returns an error' do
        result = subject.execute('eat')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Eat what")
      end
    end

    context 'when already eating' do
      let(:food_pattern) { create_test_pattern(consume_type: 'food') }
      let!(:food_item) { create_test_item(name: 'Apple', pattern: food_pattern, character_instance: character_instance) }

      before do
        character_instance.start_eating!(food_item)
      end

      it 'returns an error' do
        result = subject.execute('eat bread')
        expect(result[:success]).to be false
        expect(result[:error]).to include("already eating")
      end
    end

    context 'when item is not in inventory' do
      it 'returns an error' do
        result = subject.execute('eat pizza')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have")
      end
    end

    context 'when item is not food' do
      let(:non_food_pattern) { create_test_pattern(consume_type: nil) }
      let!(:item) { create_test_item(name: 'Sword', pattern: non_food_pattern, character_instance: character_instance) }

      it 'returns an error' do
        result = subject.execute('eat sword')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have")
      end
    end

    context 'with a valid food item in inventory' do
      let(:food_pattern) { create_test_pattern(consume_type: 'food', taste: 'Delicious!', consume_time: 5) }
      let!(:food_item) { create_test_item(name: 'Apple', pattern: food_pattern, character_instance: character_instance) }

      it 'starts eating the item' do
        result = subject.execute('eat Apple')
        expect(result[:success]).to be true
        expect(result[:message]).to include("start eating")
        expect(result[:message]).to include("Apple")
        expect(result[:message]).to include("Delicious!")
      end

      it 'sets eating state on character' do
        subject.execute('eat Apple')
        character_instance.reload
        expect(character_instance.eating?).to be true
        expect(character_instance.eating_id).to eq(food_item.id)
      end

      it 'starts consuming the item' do
        subject.execute('eat Apple')
        food_item.reload
        expect(food_item.being_consumed?).to be true
        expect(food_item.consume_remaining).to eq(5)
      end

      it 'matches item by prefix' do
        result = subject.execute('eat App')
        expect(result[:success]).to be true
        expect(result[:message]).to include("Apple")
      end
    end
  end
end
