# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CardActionHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end
  end

  describe 'instance methods' do
    it 'defines parse_draw_syntax' do
      expect(described_class.instance_methods).to include(:parse_draw_syntax)
    end

    it 'defines card_display_names' do
      expect(described_class.instance_methods).to include(:card_display_names)
    end

    it 'defines face_type_string' do
      expect(described_class.instance_methods).to include(:face_type_string)
    end

    it 'defines card_word' do
      expect(described_class.instance_methods).to include(:card_word)
    end

    it 'defines add_cards_to_holder' do
      expect(described_class.instance_methods).to include(:add_cards_to_holder)
    end

    it 'defines draw_self_message' do
      expect(described_class.instance_methods).to include(:draw_self_message)
    end

    it 'defines draw_others_message' do
      expect(described_class.instance_methods).to include(:draw_others_message)
    end

    it 'defines validate_deck_count' do
      expect(described_class.instance_methods).to include(:validate_deck_count)
    end

    it 'defines require_card_game' do
      expect(described_class.instance_methods).to include(:require_card_game)
    end
  end

  # Create a test class that includes the helper
  let(:test_class) do
    Class.new do
      include CardActionHelper

      attr_accessor :character_instance

      def blank?(val)
        val.nil? || val.to_s.strip.empty?
      end
    end
  end

  let(:instance) { test_class.new }

  describe '#parse_draw_syntax' do
    it 'returns defaults for blank input' do
      result = instance.parse_draw_syntax('')
      expect(result[:count]).to eq(1)
      expect(result[:facedown]).to be true
    end

    it 'returns defaults for nil input' do
      result = instance.parse_draw_syntax(nil)
      expect(result[:count]).to eq(1)
      expect(result[:facedown]).to be true
    end

    it 'parses number at start' do
      result = instance.parse_draw_syntax('5')
      expect(result[:count]).to eq(5)
    end

    it 'parses faceup keyword' do
      result = instance.parse_draw_syntax('faceup')
      expect(result[:facedown]).to be false
    end

    it 'parses "face up" with space' do
      result = instance.parse_draw_syntax('face up')
      expect(result[:facedown]).to be false
    end

    it 'parses combined number and faceup' do
      result = instance.parse_draw_syntax('3 faceup')
      expect(result[:count]).to eq(3)
      expect(result[:facedown]).to be false
    end

    it 'handles case insensitivity' do
      result = instance.parse_draw_syntax('FACEUP')
      expect(result[:facedown]).to be false
    end

    it 'enforces minimum count of 1' do
      result = instance.parse_draw_syntax('0')
      expect(result[:count]).to eq(1)
    end

    it 'uses custom defaults when provided' do
      result = instance.parse_draw_syntax('', default_count: 3, default_facedown: false)
      expect(result[:count]).to eq(3)
      expect(result[:facedown]).to be false
    end
  end

  describe '#card_display_names' do
    it 'returns empty array for nil' do
      expect(instance.card_display_names(nil)).to eq([])
    end

    it 'returns empty array for empty array' do
      expect(instance.card_display_names([])).to eq([])
    end

    it 'fetches card names from database' do
      card1 = double(display_name: 'Ace of Spades')
      card2 = double(display_name: 'King of Hearts')
      # Mock the dataset to respond to map directly (Sequel Dataset behavior)
      dataset = [card1, card2]
      allow(Card).to receive(:where).with(id: [1, 2]).and_return(dataset)

      result = instance.card_display_names([1, 2])
      expect(result).to eq(['Ace of Spades', 'King of Hearts'])
    end
  end

  describe '#face_type_string' do
    it 'returns "face down" when facedown is true' do
      expect(instance.face_type_string(true)).to eq('face down')
    end

    it 'returns "face up" when facedown is false' do
      expect(instance.face_type_string(false)).to eq('face up')
    end
  end

  describe '#card_word' do
    it 'returns "card" for count of 1' do
      expect(instance.card_word(1)).to eq('card')
    end

    it 'returns "cards" for count > 1' do
      expect(instance.card_word(2)).to eq('cards')
      expect(instance.card_word(5)).to eq('cards')
    end

    it 'returns "cards" for count of 0' do
      expect(instance.card_word(0)).to eq('cards')
    end
  end

  describe '#add_cards_to_holder' do
    let(:holder) { double('Holder') }

    it 'adds facedown cards to hand' do
      expect(holder).to receive(:add_cards_facedown).with([1, 2])
      instance.add_cards_to_holder(holder, [1, 2], facedown: true)
    end

    it 'adds faceup cards to hand' do
      expect(holder).to receive(:add_cards_faceup).with([1, 2])
      instance.add_cards_to_holder(holder, [1, 2], facedown: false)
    end

    it 'adds facedown cards to center when to_center is true' do
      expect(holder).to receive(:add_to_center_facedown).with([1, 2])
      instance.add_cards_to_holder(holder, [1, 2], facedown: true, to_center: true)
    end

    it 'adds faceup cards to center when to_center is true' do
      expect(holder).to receive(:add_to_center_faceup).with([1, 2])
      instance.add_cards_to_holder(holder, [1, 2], facedown: false, to_center: true)
    end
  end

  describe '#draw_self_message' do
    it 'builds message for drawing cards' do
      result = instance.draw_self_message(
        count: 2,
        facedown: true,
        card_names: ['Ace', 'King']
      )
      expect(result).to include('2 cards')
      expect(result).to include('face down')
      expect(result).to include('Ace, King')
    end

    it 'includes destination when specified' do
      result = instance.draw_self_message(
        count: 1,
        facedown: false,
        card_names: ['Queen'],
        destination: 'center'
      )
      expect(result).to include('center')
    end
  end

  describe '#draw_others_message' do
    it 'shows card names for faceup draws' do
      result = instance.draw_others_message(
        actor_name: 'Alice',
        count: 1,
        facedown: false,
        card_names: ['Ace']
      )
      expect(result).to include('Alice')
      expect(result).to include('Ace')
    end

    it 'hides card names for facedown draws' do
      result = instance.draw_others_message(
        actor_name: 'Bob',
        count: 2,
        facedown: true,
        card_names: ['Ace', 'King']
      )
      expect(result).to include('Bob')
      expect(result).to include('face down')
      expect(result).not_to include('Ace')
    end
  end

  describe '#validate_deck_count' do
    let(:deck) { double(remaining_count: 5) }

    it 'returns nil when deck has enough cards' do
      expect(instance.validate_deck_count(deck, 3)).to be_nil
    end

    it 'returns error message when deck has insufficient cards' do
      result = instance.validate_deck_count(deck, 10)
      expect(result).to include('only has 5 cards')
    end
  end

  describe '#require_card_game' do
    it 'returns deck when character is in card game' do
      deck = double('Deck')
      instance.character_instance = double(current_deck: deck)
      expect(instance.require_card_game).to eq(deck)
    end

    it 'returns nil when character is not in card game' do
      instance.character_instance = double(current_deck: nil)
      expect(instance.require_card_game).to be_nil
    end
  end
end
