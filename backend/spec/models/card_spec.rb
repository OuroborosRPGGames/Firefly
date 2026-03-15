# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Card do
  let(:character) { create(:character) }
  let(:deck_pattern) { create(:deck_pattern, creator: character) }
  let(:card) { create(:card, deck_pattern: deck_pattern, name: 'Ace of Spades', suit: 'Spades', rank: 'Ace') }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(card).to be_valid
    end

    it 'requires deck_pattern_id' do
      c = build(:card, deck_pattern: nil, name: 'Test Card')
      expect(c).not_to be_valid
    end

    it 'requires name' do
      c = build(:card, deck_pattern: deck_pattern, name: nil)
      expect(c).not_to be_valid
    end

    it 'validates max length of name' do
      c = build(:card, deck_pattern: deck_pattern, name: 'x' * 256)
      expect(c).not_to be_valid
    end

    it 'validates max length of suit' do
      c = build(:card, deck_pattern: deck_pattern, suit: 'x' * 51)
      expect(c).not_to be_valid
    end

    it 'validates max length of rank' do
      c = build(:card, deck_pattern: deck_pattern, rank: 'x' * 51)
      expect(c).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to deck_pattern' do
      expect(card.deck_pattern).to eq(deck_pattern)
    end
  end

  describe '#display_name' do
    it 'returns name for Major Arcana cards' do
      arcana_card = create(:card, deck_pattern: deck_pattern, name: 'The Fool', suit: 'Major Arcana', rank: '0')
      expect(arcana_card.display_name).to eq('The Fool')
    end

    it 'returns name for Jokers' do
      joker = create(:card, deck_pattern: deck_pattern, name: 'Red Joker', suit: 'Joker', rank: nil)
      expect(joker.display_name).to eq('Red Joker')
    end

    it 'returns rank of suit format for standard cards' do
      expect(card.display_name).to eq('Ace of Spades')
    end

    it 'returns name when suit is nil' do
      special_card = create(:card, deck_pattern: deck_pattern, name: 'Wild Card', suit: nil, rank: nil)
      expect(special_card.display_name).to eq('Wild Card')
    end

    it 'returns name when no rank' do
      no_rank_card = create(:card, deck_pattern: deck_pattern, name: 'Mystery Card', suit: 'Hearts', rank: nil)
      expect(no_rank_card.display_name).to eq('Mystery Card')
    end
  end

  describe '#short_display' do
    it 'returns name for cards without suit and rank' do
      special_card = create(:card, deck_pattern: deck_pattern, name: 'Joker', suit: nil, rank: nil)
      expect(special_card.short_display).to eq('Joker')
    end

    it 'returns A with heart symbol for Ace of Hearts' do
      hearts_card = create(:card, deck_pattern: deck_pattern, name: 'Ace of Hearts', suit: 'Hearts', rank: 'Ace')
      expect(hearts_card.short_display).to eq("A\u2665")
    end

    it 'returns K with spade symbol for King of Spades' do
      king_card = create(:card, deck_pattern: deck_pattern, name: 'King of Spades', suit: 'Spades', rank: 'King')
      expect(king_card.short_display).to eq("K\u2660")
    end

    it 'returns Q with diamond symbol for Queen of Diamonds' do
      queen_card = create(:card, deck_pattern: deck_pattern, name: 'Queen of Diamonds', suit: 'Diamonds', rank: 'Queen')
      expect(queen_card.short_display).to eq("Q\u2666")
    end

    it 'returns J with club symbol for Jack of Clubs' do
      jack_card = create(:card, deck_pattern: deck_pattern, name: 'Jack of Clubs', suit: 'Clubs', rank: 'Jack')
      expect(jack_card.short_display).to eq("J\u2663")
    end

    it 'returns number with suit symbol for number cards' do
      two_card = create(:card, deck_pattern: deck_pattern, name: '2 of Hearts', suit: 'Hearts', rank: '2')
      expect(two_card.short_display).to eq("2\u2665")
    end
  end

  describe '#face_card?' do
    it 'returns true for Jack' do
      jack = create(:card, deck_pattern: deck_pattern, rank: 'Jack')
      expect(jack.face_card?).to be true
    end

    it 'returns true for Queen' do
      queen = create(:card, deck_pattern: deck_pattern, rank: 'Queen')
      expect(queen.face_card?).to be true
    end

    it 'returns true for King' do
      king = create(:card, deck_pattern: deck_pattern, rank: 'King')
      expect(king.face_card?).to be true
    end

    it 'returns false for Ace' do
      ace = create(:card, deck_pattern: deck_pattern, rank: 'Ace')
      expect(ace.face_card?).to be false
    end

    it 'returns false for number cards' do
      five = create(:card, deck_pattern: deck_pattern, rank: '5')
      expect(five.face_card?).to be false
    end

    it 'returns false when rank is nil' do
      no_rank = create(:card, deck_pattern: deck_pattern, rank: nil)
      expect(no_rank.face_card?).to be false
    end
  end

  describe '#numeric_value' do
    it 'returns 14 for Ace' do
      expect(card.numeric_value).to eq(14)
    end

    it 'returns 13 for King' do
      king = create(:card, deck_pattern: deck_pattern, rank: 'King')
      expect(king.numeric_value).to eq(13)
    end

    it 'returns 12 for Queen' do
      queen = create(:card, deck_pattern: deck_pattern, rank: 'Queen')
      expect(queen.numeric_value).to eq(12)
    end

    it 'returns 11 for Jack' do
      jack = create(:card, deck_pattern: deck_pattern, rank: 'Jack')
      expect(jack.numeric_value).to eq(11)
    end

    it 'returns number for number cards' do
      five = create(:card, deck_pattern: deck_pattern, rank: '5')
      expect(five.numeric_value).to eq(5)
    end

    it 'returns nil when rank is nil' do
      no_rank = create(:card, deck_pattern: deck_pattern, rank: nil)
      expect(no_rank.numeric_value).to be_nil
    end
  end
end
