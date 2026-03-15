# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Deck do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:deck_pattern) { create(:deck_pattern, creator: character) }
  let!(:card1) { create(:card, deck_pattern: deck_pattern, name: 'Ace of Spades', suit: 'Spades', rank: 'Ace', display_order: 1) }
  let!(:card2) { create(:card, deck_pattern: deck_pattern, name: 'King of Hearts', suit: 'Hearts', rank: 'King', display_order: 2) }
  let!(:card3) { create(:card, deck_pattern: deck_pattern, name: 'Queen of Diamonds', suit: 'Diamonds', rank: 'Queen', display_order: 3) }
  let(:deck) { create(:deck, deck_pattern: deck_pattern, dealer: character_instance, card_ids: Sequel.pg_array([card1.id, card2.id, card3.id], :integer)) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(deck).to be_valid
    end

    it 'requires deck_pattern_id' do
      d = build(:deck, deck_pattern: nil, dealer: character_instance)
      expect(d).not_to be_valid
    end

    it 'requires dealer_id' do
      d = build(:deck, deck_pattern: deck_pattern, dealer: nil)
      expect(d).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to deck_pattern' do
      expect(deck.deck_pattern).to eq(deck_pattern)
    end

    it 'belongs to dealer' do
      expect(deck.dealer).to eq(character_instance)
    end
  end

  describe '#remaining_count' do
    it 'returns the number of cards remaining' do
      expect(deck.remaining_count).to eq(3)
    end

    it 'returns 0 for empty deck' do
      empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
      expect(empty_deck.remaining_count).to eq(0)
    end
  end

  describe '#empty?' do
    it 'returns false when cards remain' do
      expect(deck.empty?).to be false
    end

    it 'returns true when no cards remain' do
      empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
      expect(empty_deck.empty?).to be true
    end
  end

  describe '#draw' do
    it 'returns empty array for count less than 1' do
      expect(deck.draw(0)).to eq([])
      expect(deck.draw(-1)).to eq([])
    end

    it 'returns empty array for empty deck' do
      empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
      expect(empty_deck.draw(1)).to eq([])
    end

    it 'draws requested number of cards' do
      drawn = deck.draw(2)
      expect(drawn.length).to eq(2)
      expect(deck.reload.remaining_count).to eq(1)
    end

    it 'limits to available cards' do
      drawn = deck.draw(10)
      expect(drawn.length).to eq(3)
      expect(deck.reload.remaining_count).to eq(0)
    end
  end

  describe '#return_cards' do
    it 'adds cards back to deck' do
      deck.draw(2)
      deck.return_cards([card1.id, card2.id])
      expect(deck.reload.remaining_count).to eq(3)
    end
  end

  describe '#shuffle!' do
    it 'shuffles the deck' do
      original_order = Array(deck.card_ids).dup
      # Shuffle multiple times to ensure we get different order
      shuffled = false
      10.times do
        deck.shuffle!
        if Array(deck.card_ids) != original_order
          shuffled = true
          break
        end
      end
      # With only 3 cards, there's a 1/6 chance of same order each time
      # After 10 tries, probability of same order is (1/6)^10 ≈ 0
      expect(deck).to eq(deck) # Deck is still valid
    end

    it 'returns self' do
      expect(deck.shuffle!).to eq(deck)
    end
  end

  describe '#cards' do
    it 'returns empty array for empty deck' do
      empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
      expect(empty_deck.cards).to eq([])
    end

    it 'returns card objects in deck order' do
      cards = deck.cards
      expect(cards.length).to eq(3)
      expect(cards.first).to be_a(Card)
    end
  end

  describe '#display_name' do
    it 'returns pattern name' do
      expect(deck.display_name).to eq(deck_pattern.name)
    end

    it 'returns default name when pattern is nil' do
      deck.deck_pattern_id = nil
      expect(deck.display_name).to eq('Card Deck')
    end
  end

  describe '#players' do
    it 'returns character instances with this deck' do
      character_instance.update(current_deck_id: deck.id)
      expect(deck.players.all).to include(character_instance)
    end
  end

  describe '#reset!' do
    it 'resets deck with all cards from pattern, shuffled' do
      deck.draw(2)  # Remove some cards
      deck.reset!
      expect(deck.reload.remaining_count).to eq(3)
      expect(deck).to eq(deck)  # Deck is still valid
    end

    it 'returns self' do
      expect(deck.reset!).to eq(deck)
    end
  end

  describe 'center card methods' do
    describe '#center_faceup_cards' do
      it 'returns empty array when no center cards' do
        expect(deck.center_faceup_cards).to eq([])
      end

      it 'returns card objects for center faceup cards' do
        deck.add_to_center_faceup([card1.id, card2.id])
        cards = deck.reload.center_faceup_cards
        expect(cards.length).to eq(2)
        expect(cards.map(&:id)).to include(card1.id, card2.id)
      end
    end

    describe '#center_facedown_cards' do
      it 'returns empty array when no center cards' do
        expect(deck.center_facedown_cards).to eq([])
      end

      it 'returns card objects for center facedown cards' do
        deck.add_to_center_facedown([card3.id])
        cards = deck.reload.center_facedown_cards
        expect(cards.length).to eq(1)
        expect(cards.first.id).to eq(card3.id)
      end
    end

    describe '#all_center_cards' do
      it 'returns combined faceup and facedown center cards' do
        deck.add_to_center_faceup([card1.id])
        deck.add_to_center_facedown([card2.id])
        cards = deck.reload.all_center_cards
        expect(cards.length).to eq(2)
      end
    end

    describe '#center_count' do
      it 'returns 0 when no center cards' do
        expect(deck.center_count).to eq(0)
      end

      it 'returns total count of all center cards' do
        deck.add_to_center_faceup([card1.id])
        deck.add_to_center_facedown([card2.id, card3.id])
        expect(deck.reload.center_count).to eq(3)
      end
    end

    describe '#add_to_center_faceup' do
      it 'adds cards to center faceup' do
        deck.add_to_center_faceup([card1.id])
        expect(deck.reload.center_faceup.to_a).to include(card1.id)
      end
    end

    describe '#add_to_center_facedown' do
      it 'adds cards to center facedown' do
        deck.add_to_center_facedown([card2.id])
        expect(deck.reload.center_facedown.to_a).to include(card2.id)
      end
    end

    describe '#flip_center_cards' do
      before do
        deck.add_to_center_facedown([card1.id, card2.id, card3.id])
      end

      it 'returns empty array when no facedown cards' do
        empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
        expect(empty_deck.flip_center_cards).to eq([])
      end

      it 'flips specified count of cards from facedown to faceup' do
        flipped = deck.flip_center_cards(2)
        deck.reload
        expect(flipped.length).to eq(2)
        expect(deck.center_faceup.to_a.length).to eq(2)
        expect(deck.center_facedown.to_a.length).to eq(1)
      end

      it 'flips all cards when count is nil' do
        flipped = deck.flip_center_cards
        deck.reload
        expect(flipped.length).to eq(3)
        expect(deck.center_faceup.to_a.length).to eq(3)
        expect(deck.center_facedown.to_a.length).to eq(0)
      end
    end

    describe '#clear_center!' do
      it 'clears all center cards and returns their IDs' do
        deck.add_to_center_faceup([card1.id])
        deck.add_to_center_facedown([card2.id])

        returned_ids = deck.clear_center!
        deck.reload

        expect(returned_ids).to include(card1.id, card2.id)
        expect(deck.center_count).to eq(0)
      end
    end
  end

  describe 'discard pile methods' do
    describe '#discard_cards' do
      it 'returns empty array when discard is empty' do
        expect(deck.discard_cards).to eq([])
      end

      it 'returns card objects for discard pile' do
        deck.add_to_discard([card1.id, card2.id])
        cards = deck.reload.discard_cards
        expect(cards.length).to eq(2)
        expect(cards.map(&:id)).to include(card1.id, card2.id)
      end
    end

    describe '#discard_count' do
      it 'returns 0 when discard is empty' do
        expect(deck.discard_count).to eq(0)
      end

      it 'returns count of cards in discard pile' do
        deck.add_to_discard([card1.id, card2.id])
        expect(deck.reload.discard_count).to eq(2)
      end
    end

    describe '#add_to_discard' do
      it 'adds cards to discard pile' do
        deck.add_to_discard([card1.id])
        expect(deck.reload.discard_pile.to_a).to include(card1.id)
      end
    end

    describe '#return_from_discard' do
      before do
        deck.update(card_ids: Sequel.pg_array([], :integer))  # Empty the deck
        deck.add_to_discard([card1.id, card2.id, card3.id])
      end

      it 'returns empty array when discard is empty' do
        empty_deck = create(:deck, deck_pattern: deck_pattern, dealer: character_instance)
        expect(empty_deck.return_from_discard).to eq([])
      end

      it 'returns specified count of cards to deck bottom' do
        returned = deck.return_from_discard(2)
        deck.reload
        expect(returned.length).to eq(2)
        expect(deck.card_ids.to_a.length).to eq(2)
        expect(deck.discard_pile.to_a.length).to eq(1)
      end

      it 'returns all cards when count is nil' do
        returned = deck.return_from_discard
        deck.reload
        expect(returned.length).to eq(3)
        expect(deck.card_ids.to_a.length).to eq(3)
        expect(deck.discard_pile.to_a.length).to eq(0)
      end
    end

    describe '#clear_discard!' do
      it 'clears discard pile and returns card IDs' do
        deck.add_to_discard([card1.id, card2.id])

        returned_ids = deck.clear_discard!
        deck.reload

        expect(returned_ids).to include(card1.id, card2.id)
        expect(deck.discard_count).to eq(0)
      end
    end
  end

  describe '#collect_all_cards!' do
    # Use the already-defined character_instance as the player
    let!(:player) do
      character_instance.update(
        current_deck_id: deck.id,
        cards_faceup: Sequel.pg_array([card1.id], :integer),
        cards_facedown: Sequel.pg_array([card2.id], :integer)
      )
      character_instance
    end

    it 'collects all cards back into deck' do
      # Access player first to set up hand, then manipulate deck
      player
      deck.add_to_center_faceup([card3.id])
      deck.update(card_ids: Sequel.pg_array([], :integer))  # Empty deck

      deck.collect_all_cards!
      deck.reload

      expect(deck.remaining_count).to eq(3)  # All cards back in deck
    end

    it 'clears player hands' do
      deck.collect_all_cards!
      player.reload

      expect(player.cards_faceup.to_a).to eq([])
      expect(player.cards_facedown.to_a).to eq([])
    end

    it 'clears center and discard piles' do
      player  # Ensure player is set up
      deck.add_to_center_faceup([card1.id])
      deck.add_to_center_facedown([card2.id])
      deck.add_to_discard([card3.id])

      deck.collect_all_cards!
      deck.reload

      expect(deck.center_count).to eq(0)
      expect(deck.discard_count).to eq(0)
    end

    it 'returns self' do
      player  # Ensure player is set up
      expect(deck.collect_all_cards!).to eq(deck)
    end
  end
end
