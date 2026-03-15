# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DeckPattern do
  let(:character) { create(:character) }
  let(:deck_pattern) { create(:deck_pattern, creator: character) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(deck_pattern).to be_valid
    end

    it 'requires name' do
      dp = build(:deck_pattern, creator: character, name: nil)
      expect(dp).not_to be_valid
    end

    it 'validates max length of name' do
      dp = build(:deck_pattern, creator: character, name: 'x' * 256)
      expect(dp).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to creator' do
      expect(deck_pattern.creator).to eq(character)
    end

    it 'has many cards' do
      expect(deck_pattern).to respond_to(:cards)
    end

    it 'has many decks' do
      expect(deck_pattern).to respond_to(:decks)
    end

    it 'has many deck_ownerships' do
      expect(deck_pattern).to respond_to(:deck_ownerships)
    end
  end

  describe '#card_count' do
    it 'returns 0 for pattern with no cards' do
      expect(deck_pattern.card_count).to eq(0)
    end

    it 'returns count of cards' do
      create(:card, deck_pattern: deck_pattern)
      create(:card, deck_pattern: deck_pattern)
      expect(deck_pattern.card_count).to eq(2)
    end
  end

  describe '#owned_by?' do
    let(:other_character) { create(:character) }

    it 'returns true for public decks' do
      deck_pattern.update(is_public: true)
      expect(deck_pattern.owned_by?(other_character)).to be true
    end

    it 'returns true for creator' do
      deck_pattern.update(is_public: false)
      expect(deck_pattern.owned_by?(character)).to be true
    end

    it 'returns false for non-owner of private deck' do
      deck_pattern.update(is_public: false)
      expect(deck_pattern.owned_by?(other_character)).to be false
    end
  end

  describe '#grant_to' do
    let(:other_character) { create(:character) }

    before do
      deck_pattern.update(is_public: false)
    end

    it 'grants ownership to a character' do
      deck_pattern.grant_to(other_character)
      expect(deck_pattern.owned_by?(other_character)).to be true
    end

    it 'does not duplicate ownership' do
      deck_pattern.grant_to(other_character)
      expect { deck_pattern.grant_to(other_character) }.not_to change { DeckOwnership.count }
    end
  end

  describe '#accessible_by?' do
    let(:other_character) { create(:character) }

    it 'returns true for public decks' do
      deck_pattern.update(is_public: true)
      expect(deck_pattern.accessible_by?(other_character)).to be true
    end

    it 'returns true when owned' do
      deck_pattern.update(is_public: false)
      deck_pattern.grant_to(other_character)
      expect(deck_pattern.accessible_by?(other_character)).to be true
    end

    it 'returns false when not public and not owned' do
      deck_pattern.update(is_public: false)
      expect(deck_pattern.accessible_by?(other_character)).to be false
    end
  end

  describe '#create_deck_for' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }

    before do
      create(:card, deck_pattern: deck_pattern, display_order: 1)
      create(:card, deck_pattern: deck_pattern, display_order: 2)
    end

    it 'creates a new deck for the character instance' do
      deck = deck_pattern.create_deck_for(character_instance)
      expect(deck).to be_a(Deck)
      expect(deck.dealer).to eq(character_instance)
      expect(deck.deck_pattern).to eq(deck_pattern)
    end

    it 'shuffles the cards into the deck' do
      deck = deck_pattern.create_deck_for(character_instance)
      expect(deck.remaining_count).to eq(2)
    end
  end

  describe '.accessible_by' do
    let(:other_character) { create(:character) }
    let!(:public_pattern) { create(:deck_pattern, creator: character, is_public: true) }
    let!(:private_pattern) { create(:deck_pattern, creator: character, is_public: false) }

    it 'returns public patterns' do
      results = described_class.accessible_by(other_character).all
      expect(results).to include(public_pattern)
    end

    it 'does not return unowned private patterns' do
      results = described_class.accessible_by(other_character).all
      expect(results).not_to include(private_pattern)
    end

    it 'returns owned private patterns' do
      private_pattern.grant_to(other_character)
      results = described_class.accessible_by(other_character).all
      expect(results).to include(private_pattern)
    end
  end
end
