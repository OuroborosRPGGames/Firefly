# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CardsQuickmenuHandler do
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, current_room: room) }
  let(:deck) { nil }

  before do
    allow(character_instance).to receive(:current_deck).and_return(deck)
    allow(character_instance).to receive(:current_room).and_return(room)
  end

  describe '.show_menu' do
    it 'creates handler and shows current menu' do
      result = described_class.show_menu(character_instance)
      expect(result[:type]).to eq(:quickmenu)
    end
  end

  describe '.handle_response' do
    it 'creates handler and handles response' do
      result = described_class.handle_response(character_instance, { stage: 'main_menu' }, 'close')
      expect(result[:success]).to be true
    end
  end

  describe '#show_current_menu' do
    context 'when player has no deck' do
      it 'shows start game menu' do
        result = described_class.show_menu(character_instance)

        expect(result[:prompt]).to eq('Choose a deck type:')
        expect(result[:options].map { |o| o[:key] }).to include('standard', 'jokers', 'tarot')
      end
    end

    context 'when player has a deck' do
      let(:deck) { instance_double(Deck, remaining_count: 52, discard_count: 0, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

      before do
        allow(character_instance).to receive(:has_cards?).and_return(false)
      end

      it 'shows main menu' do
        result = described_class.show_menu(character_instance)

        expect(result[:prompt]).to eq('Card Actions:')
        expect(result[:options].map { |o| o[:key] }).to include('draw', 'close')
      end
    end
  end

  describe '#handle_response' do
    subject(:handler) { described_class.new(character_instance, context) }
    let(:context) { {} }

    context 'when closing menu' do
      it 'returns success message' do
        result = handler.handle_response('close')

        expect(result[:success]).to be true
        expect(result[:message]).to eq('Card menu closed.')
      end

      it 'handles cancel as close' do
        result = handler.handle_response('cancel')

        expect(result[:success]).to be true
      end
    end

    context 'when going back' do
      it 'returns to main menu' do
        allow(character_instance).to receive(:current_deck).and_return(
          instance_double(Deck, remaining_count: 52, discard_count: 0, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: [])
        )
        allow(character_instance).to receive(:has_cards?).and_return(false)

        result = handler.handle_response('back')

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to eq('Card Actions:')
      end
    end
  end

  describe 'start game flow' do
    subject(:handler) { described_class.new(character_instance) }

    context 'when starting a game' do
      let(:deck_pattern) { instance_double(DeckPattern, id: 1) }
      let(:new_deck) { instance_double(Deck, id: 1, remaining_count: 52, discard_count: 0, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

      before do
        allow(character_instance).to receive(:current_deck).and_return(nil, new_deck)
        allow(character_instance).to receive(:has_cards?).and_return(false)
        allow(character_instance).to receive(:full_name).and_return('Test Player')
        allow(character_instance).to receive(:character).and_return(double)
        allow(character_instance).to receive(:join_card_game!)
        allow(Deck).to receive(:create).and_return(new_deck)
        allow(new_deck).to receive(:reset!)
        allow(DeckPattern).to receive(:first).and_return(deck_pattern)
        allow(room).to receive(:character_instances).and_return([])
      end

      it 'creates standard deck' do
        expect(Deck).to receive(:create).with(hash_including(deck_pattern_id: deck_pattern.id))

        result = handler.send(:handle_start_game, 'standard')

        expect(result[:message]).to include('standard deck')
      end

      it 'rejects invalid deck type' do
        result = handler.send(:handle_start_game, 'invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid deck type.')
      end

      it 'rejects if already has deck' do
        allow(character_instance).to receive(:current_deck).and_return(new_deck)

        result = handler.send(:handle_start_game, 'standard')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already have a deck')
      end
    end
  end

  describe 'main menu navigation' do
    subject(:handler) { described_class.new(character_instance, { stage: 'main_menu' }) }
    let(:deck) { instance_double(Deck, remaining_count: 52, discard_count: 5, center_count: 3, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:has_cards?).and_return(true)
      allow(character_instance).to receive(:cards_facedown).and_return([])
    end

    it 'navigates to draw count stage' do
      result = handler.send(:handle_main_menu, 'draw')

      expect(result[:context][:stage]).to eq('draw_count')
    end

    it 'navigates to play card stage' do
      result = handler.send(:handle_main_menu, 'play')

      expect(result[:context][:stage]).to eq('play_card')
    end

    it 'navigates to discard stage' do
      result = handler.send(:handle_main_menu, 'discard')

      expect(result[:context][:stage]).to eq('discard_card')
    end

    it 'navigates to deal count stage' do
      result = handler.send(:handle_main_menu, 'deal')

      expect(result[:context][:stage]).to eq('deal_count')
    end

    it 'navigates to center draw stage' do
      result = handler.send(:handle_main_menu, 'centerdraw')

      expect(result[:context][:stage]).to eq('center_draw_count')
    end

    it 'returns error for invalid action' do
      result = handler.send(:handle_main_menu, 'invalid')

      expect(result[:success]).to be false
    end

    it 'rejects dealer-only action for non-dealers' do
      allow(deck).to receive(:dealer_id).and_return(999_999)

      result = handler.send(:handle_main_menu, 'deal')

      expect(result[:success]).to be false
      expect(result[:error]).to include("not the dealer")
    end
  end

  describe 'draw flow' do
    subject(:handler) { described_class.new(character_instance, context) }
    let(:context) { { stage: 'draw_count' } }
    let(:deck) { instance_double(Deck, remaining_count: 10, discard_count: 0, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
    end

    describe '#handle_draw_count' do
      it 'proceeds to face selection with valid count' do
        result = handler.send(:handle_draw_count, '3')

        expect(result[:context][:stage]).to eq('draw_face')
        expect(result[:context][:draw_count]).to eq(3)
      end

      it 'handles all option' do
        result = handler.send(:handle_draw_count, 'all')

        expect(result[:context][:draw_count]).to eq(10)
      end

      it 'rejects invalid count' do
        result = handler.send(:handle_draw_count, '99')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid count.')
      end

      it 'rejects zero count' do
        result = handler.send(:handle_draw_count, '0')

        expect(result[:success]).to be false
      end
    end

    describe '#handle_draw_face' do
      let(:context) { { stage: 'draw_face', draw_count: 2 } }
      let(:card_ids) { [1, 2] }
      let(:cards) { card_ids.map { |id| instance_double(Card, id: id, display_name: "Card #{id}") } }

      before do
        allow(deck).to receive(:draw).and_return(card_ids)
        allow(character_instance).to receive(:add_cards_facedown)
        allow(character_instance).to receive(:add_cards_faceup)
        allow(character_instance).to receive(:has_cards?).and_return(true)
        allow(character_instance).to receive(:full_name).and_return('Test Player')
        allow(room).to receive(:character_instances).and_return([])
        allow(Card).to receive(:[]) do |id|
          cards.find { |c| c.id == id }
        end
      end

      it 'draws cards face down' do
        expect(character_instance).to receive(:add_cards_facedown).with(card_ids)

        result = handler.send(:handle_draw_face, 'facedown')

        expect(result[:data][:facedown]).to be true
      end

      it 'draws cards face up' do
        expect(character_instance).to receive(:add_cards_faceup).with(card_ids)

        result = handler.send(:handle_draw_face, 'faceup')

        expect(result[:data][:facedown]).to be false
      end

      it 'returns error if not in game' do
        allow(character_instance).to receive(:current_deck).and_return(nil)

        result = handler.send(:handle_draw_face, 'facedown')

        expect(result[:success]).to be false
      end
    end
  end

  describe 'dealer action guards' do
    subject(:handler) { described_class.new(character_instance, context) }

    let(:context) { { stage: 'deal_count' } }
    let(:deck) do
      instance_double(
        Deck,
        id: 10,
        remaining_count: 10,
        discard_count: 0,
        center_count: 0,
        dealer_id: character_instance.id,
        center_facedown: [],
        center_faceup: [],
        center_faceup_cards: []
      )
    end

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:current_room_id).and_return(room.id)
      allow(room).to receive(:instances_dataset).and_return(double(exclude: double(all: [])))
    end

    it 'accepts all for deal_count' do
      result = handler.send(:handle_deal_count, 'all')

      expect(result[:context][:stage]).to eq('deal_player')
      expect(result[:context][:deal_count]).to eq(10)
    end

    it 'accepts all for center_draw_count' do
      center_handler = described_class.new(character_instance, { stage: 'center_draw_count' })
      result = center_handler.send(:handle_center_draw_count, 'all')

      expect(result[:context][:stage]).to eq('center_draw_face')
      expect(result[:context][:draw_count]).to eq(10)
    end

    it 'rejects deal selection when target is in a different game' do
      other_deck_target = instance_double(
        CharacterInstance,
        current_room_id: room.id,
        in_card_game?: true,
        current_deck_id: 99
      )
      allow(CharacterInstance).to receive(:[]).with(123).and_return(other_deck_target)

      result = handler.send(:handle_deal_player, '123')

      expect(result[:success]).to be false
      expect(result[:error]).to include('different card game')
    end

    it 'rejects dealer flows for non-dealers' do
      allow(deck).to receive(:dealer_id).and_return(999_999)
      result = handler.send(:handle_center_turnover_count, '1')

      expect(result[:success]).to be false
      expect(result[:error]).to include("not the dealer")
    end
  end

  describe 'play card flow' do
    subject(:handler) { described_class.new(character_instance, context) }
    let(:context) { { stage: 'play_card' } }
    let(:deck) { instance_double(Deck, remaining_count: 52, discard_count: 0, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }
    let(:card) { instance_double(Card, id: 42, display_name: 'Ace of Spades') }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:all_card_ids).and_return([42])
      allow(Card).to receive(:[]).with(42).and_return(card)
    end

    describe '#handle_play_card' do
      it 'proceeds to face selection with valid card' do
        result = handler.send(:handle_play_card, '42')

        expect(result[:context][:stage]).to eq('play_face')
        expect(result[:context][:selected_card_id]).to eq(42)
      end

      it 'rejects card not in hand' do
        allow(character_instance).to receive(:all_card_ids).and_return([])

        result = handler.send(:handle_play_card, '42')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have that card")
      end
    end

    describe '#handle_play_face' do
      let(:context) { { stage: 'play_face', selected_card_id: 42 } }

      before do
        allow(character_instance).to receive(:remove_card)
        allow(character_instance).to receive(:has_cards?).and_return(true)
        allow(character_instance).to receive(:card_count).and_return(4)
        allow(character_instance).to receive(:full_name).and_return('Test Player')
        allow(room).to receive(:character_instances).and_return([])
      end

      it 'plays card face down' do
        result = handler.send(:handle_play_face, 'facedown')

        expect(result[:data][:facedown]).to be true
        expect(result[:message]).to include('face down')
      end

      it 'plays card face up' do
        result = handler.send(:handle_play_face, 'faceup')

        expect(result[:data][:facedown]).to be false
        expect(result[:message]).to include('face up')
      end
    end
  end

  describe 'discard flow' do
    subject(:handler) { described_class.new(character_instance, context) }
    let(:context) { { stage: 'discard_face', selected_card_id: 42 } }
    let(:deck) { instance_double(Deck, remaining_count: 50, discard_count: 2, center_count: 0, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }
    let(:card) { instance_double(Card, id: 42, display_name: 'Two of Hearts') }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:all_card_ids).and_return([42])
      allow(character_instance).to receive(:remove_card)
      allow(character_instance).to receive(:has_cards?).and_return(true)
      allow(character_instance).to receive(:card_count).and_return(4)
      allow(character_instance).to receive(:full_name).and_return('Test Player')
      allow(deck).to receive(:add_to_discard)
      allow(room).to receive(:character_instances).and_return([])
      allow(Card).to receive(:[]).with(42).and_return(card)
    end

    it 'discards card face down' do
      result = handler.send(:handle_discard_face, 'facedown')

      expect(result[:data][:facedown]).to be true
    end

    it 'discards card face up' do
      result = handler.send(:handle_discard_face, 'faceup')

      expect(result[:data][:facedown]).to be false
    end
  end

  describe 'dealer-only actions' do
    subject(:handler) { described_class.new(character_instance, context) }
    let(:context) { {} }
    let(:deck) { instance_double(Deck, id: 1, remaining_count: 52, discard_count: 5, center_count: 3, dealer_id: character_instance.id, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:full_name).and_return('Test Player')
      allow(room).to receive(:character_instances).and_return([])
    end

    describe '#execute_reshuffle' do
      let(:players) { double(all: [], count: 1) }

      before do
        allow(Deck).to receive(:where).and_return(double(order: double(first: deck)))
        allow(deck).to receive(:players).and_return(players)
        allow(deck).to receive(:collect_all_cards!)
        allow(character_instance).to receive(:has_cards?).and_return(false)
      end

      it 'reshuffles the deck' do
        expect(deck).to receive(:collect_all_cards!)

        result = handler.send(:execute_reshuffle)

        expect(result[:data][:action]).to eq('reshuffle')
      end
    end

    describe '#execute_leave_game' do
      before do
        allow(character_instance).to receive(:clear_cards!)
        allow(character_instance).to receive(:leave_card_game!)
        allow(character_instance).to receive(:has_cards?).and_return(false)
      end

      it 'leaves the game' do
        result = handler.send(:execute_leave_game)

        expect(result[:success]).to be true
        expect(result[:message]).to eq('You leave the card game.')
      end
    end
  end

  describe 'option builders' do
    subject(:handler) { described_class.new(character_instance) }
    let(:deck) { instance_double(Deck, remaining_count: 10, discard_count: 0, center_count: 0, dealer_id: 999, center_facedown: [], center_faceup: [], center_faceup_cards: []) }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
    end

    describe '#build_count_options' do
      it 'builds options up to max count' do
        options = handler.send(:build_count_options, max_count: 5)

        keys = options.map { |o| o[:key] }
        expect(keys).to include('1', '2', '3', '5', 'all', 'back')
        expect(keys).not_to include('10')
      end

      it 'respects max count limit' do
        options = handler.send(:build_count_options, max_count: 2)

        keys = options.map { |o| o[:key] }
        expect(keys).to include('1', '2')
        expect(keys).not_to include('3', '5')
      end
    end

    describe '#build_face_options' do
      it 'returns face up and face down options' do
        options = handler.send(:build_face_options)

        keys = options.map { |o| o[:key] }
        expect(keys).to eq(%w[facedown faceup back])
      end
    end

    describe '#build_start_game_options' do
      it 'includes all deck types' do
        options = handler.send(:build_start_game_options)

        keys = options.map { |o| o[:key] }
        expect(keys).to include('standard', 'jokers', 'tarot', 'close')
      end
    end
  end

  describe 'helper methods' do
    subject(:handler) { described_class.new(character_instance) }
    let(:deck) { instance_double(Deck, remaining_count: 10, discard_count: 5, dealer_id: character_instance.id, center_facedown: [1, 2], center_faceup: [], center_faceup_cards: []) }

    before do
      allow(character_instance).to receive(:current_deck).and_return(deck)
      allow(character_instance).to receive(:cards_facedown).and_return([3, 4, 5])
    end

    describe '#deck_remaining_count' do
      it 'returns deck remaining count' do
        expect(handler.send(:deck_remaining_count)).to eq(10)
      end

      it 'returns 0 if no deck' do
        allow(character_instance).to receive(:current_deck).and_return(nil)
        expect(handler.send(:deck_remaining_count)).to eq(0)
      end
    end

    describe '#facedown_count_in_hand' do
      it 'returns count of facedown cards' do
        expect(handler.send(:facedown_count_in_hand)).to eq(3)
      end
    end

    describe '#center_facedown_count' do
      it 'returns count of center facedown cards' do
        expect(handler.send(:center_facedown_count)).to eq(2)
      end
    end

    describe '#is_dealer?' do
      it 'returns true when character is dealer' do
        expect(handler.send(:is_dealer?)).to be true
      end

      it 'returns false when character is not dealer' do
        allow(deck).to receive(:dealer_id).and_return(999)
        expect(handler.send(:is_dealer?)).to be false
      end
    end

    describe '#blank?' do
      it 'returns true for nil' do
        expect(handler.send(:blank?, nil)).to be true
      end

      it 'returns true for empty string' do
        expect(handler.send(:blank?, '')).to be true
      end

      it 'returns true for whitespace' do
        expect(handler.send(:blank?, '   ')).to be true
      end

      it 'returns false for non-blank' do
        expect(handler.send(:blank?, 'hello')).to be false
      end
    end
  end
end
