# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Cards::Cards, type: :command do
  let(:character) { create(:character) }
  let(:room) { create(:room) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room, online: true) }

  subject(:command) { described_class.new(char_instance) }

  # Mock deck objects
  let(:deck_pattern) { create(:deck_pattern) }
  let(:deck) do
    create(:deck,
           deck_pattern: deck_pattern,
           dealer_id: char_instance.id,
           card_ids: [1, 2, 3, 4, 5])
  end

  before do
    allow(OutputHelper).to receive(:broadcast_to_room)
    allow(OutputHelper).to receive(:send_to_character)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('cards')
    end

    it 'has correct aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('card')
      expect(alias_names).to include('cardgame')
      expect(alias_names).to include('cardmenu')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:entertainment)
    end

    it 'has help text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'when not in a card game' do
      it 'returns quickmenu with start_game options' do
        result = command.execute('cards')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:display_type]).to eq(:quickmenu)
        expect(result[:prompt]).to eq('Choose a deck type:')
        expect(result[:data]).to include(:interaction_id, :prompt, :options)
        expect(result[:data][:prompt]).to eq('Choose a deck type:')
      end

      it 'includes deck type options' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('standard')
        expect(option_keys).to include('jokers')
        expect(option_keys).to include('tarot')
      end

      it 'includes close option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('close')
      end

      it 'includes context with cards command' do
        result = command.execute('cards')

        expect(result[:context][:command]).to eq('cards')
        expect(result[:context][:stage]).to eq('start_game')
      end
    end

    context 'when in a card game' do
      before do
        char_instance.update(current_deck_id: deck.id)
      end

      it 'returns quickmenu with main_menu options' do
        result = command.execute('cards')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to eq('Card Actions:')
      end

      it 'includes draw option when deck has cards' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('draw')
      end

      it 'includes leave option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('leave')
      end

      it 'includes dealer options when dealer' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('deal')
        expect(option_keys).to include('reshuffle')
      end
    end

    context 'when player has cards' do
      let(:card) { create(:card, deck_pattern: deck_pattern, name: 'Ace', suit: 'Spades') }

      before do
        char_instance.update(
          current_deck_id: deck.id,
          cards_faceup: Sequel.pg_array([card.id], :integer)
        )
      end

      it 'includes play option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('play')
      end

      it 'includes discard option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('discard')
      end

      it 'includes showhand option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('showhand')
      end
    end

    context 'when player has facedown cards' do
      let(:card) { create(:card, deck_pattern: deck_pattern, name: 'Ace', suit: 'Spades') }

      before do
        char_instance.update(
          current_deck_id: deck.id,
          cards_facedown: Sequel.pg_array([card.id], :integer)
        )
      end

      it 'includes turnover option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('turnover')
      end
    end

    context 'when deck has discard pile' do
      before do
        char_instance.update(current_deck_id: deck.id)
        deck.update(discard_pile: Sequel.pg_array([1, 2], :integer))
      end

      it 'includes viewdiscard option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('viewdiscard')
      end

      it 'includes return option for dealer' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('return')
      end
    end

    context 'when deck has center cards' do
      before do
        char_instance.update(current_deck_id: deck.id)
        deck.update(center_faceup: Sequel.pg_array([1], :integer))
      end

      it 'includes viewcenter option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('viewcenter')
      end
    end

    context 'when deck has center facedown cards' do
      before do
        char_instance.update(current_deck_id: deck.id)
        deck.update(center_facedown: Sequel.pg_array([1, 2], :integer))
      end

      it 'includes centerturnover option for dealer' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).to include('centerturnover')
      end
    end

    context 'when deck is empty' do
      before do
        char_instance.update(current_deck_id: deck.id)
        deck.update(card_ids: Sequel.pg_array([], :integer))
      end

      it 'does not include draw option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).not_to include('draw')
      end

      it 'does not include centerdraw option' do
        result = command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).not_to include('centerdraw')
      end
    end

    context 'when player is not dealer' do
      let(:other_char) { create(:character) }
      let(:other_instance) { create(:character_instance, character: other_char, current_room: room, online: true) }

      before do
        # Make other_instance not the dealer
        deck.update(dealer_id: char_instance.id)
        other_instance.update(current_deck_id: deck.id)
      end

      it 'does not include dealer-only options' do
        other_command = described_class.new(other_instance)
        result = other_command.execute('cards')
        option_keys = result[:options].map { |o| o[:key] }

        expect(option_keys).not_to include('deal')
        expect(option_keys).not_to include('reshuffle')
        expect(option_keys).not_to include('centerdraw')
        expect(option_keys).not_to include('centerturnover')
        expect(option_keys).not_to include('return')
      end
    end
  end

  describe 'aliases' do
    it 'works with card alias' do
      result = command.execute('card')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end

    it 'works with cardgame alias' do
      result = command.execute('cardgame')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end

    it 'works with cardmenu alias' do
      result = command.execute('cardmenu')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
    end
  end
end
