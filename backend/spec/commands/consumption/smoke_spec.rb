# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Consumption::Smoke do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'without an item name' do
      it 'returns an error' do
        result = subject.execute('smoke')
        expect(result[:success]).to be false
        expect(result[:error]).to include("Smoke what")
      end
    end

    context 'when already smoking' do
      let(:smoke_pattern) { create_test_pattern(consume_type: 'smoke') }
      let!(:smoke_item) { create_test_item(name: 'Cigarette', pattern: smoke_pattern, character_instance: character_instance) }

      before do
        character_instance.start_smoking!(smoke_item)
      end

      it 'returns an error' do
        result = subject.execute('smoke cigar')
        expect(result[:success]).to be false
        expect(result[:error]).to include("already smoking")
      end
    end

    context 'with a valid smokeable item in inventory' do
      let(:smoke_pattern) { create_test_pattern(consume_type: 'smoke', taste: 'Aromatic tobacco.', consume_time: 10) }
      let!(:smoke_item) { create_test_item(name: 'Cigar', pattern: smoke_pattern, character_instance: character_instance) }

      it 'starts smoking the item' do
        result = subject.execute('smoke Cigar')
        expect(result[:success]).to be true
        expect(result[:message]).to include("start smoking")
        expect(result[:message]).to include("Cigar")
        expect(result[:message]).to include("Aromatic tobacco")
      end

      it 'sets smoking state on character' do
        subject.execute('smoke Cigar')
        character_instance.reload
        expect(character_instance.smoking?).to be true
        expect(character_instance.smoking_id).to eq(smoke_item.id)
      end
    end
  end
end
