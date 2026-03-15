# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Crafting::Fabricate, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  # Default room is a replicator (universal facility)
  let(:room) { create(:room, location: location, room_type: 'replicator') }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  let(:unified_type) do
    DB[:unified_object_types].insert(
      name: 'Clothing',
      category: 'Top',
      created_at: Time.now,
      updated_at: Time.now
    )
    UnifiedObjectType.order(:id).last
  end

  let!(:pattern) do
    DB[:patterns].insert(
      description: 'Silk Dress',
      unified_object_type_id: unified_type.id,
      price: 100,
      created_at: Time.now,
      updated_at: Time.now
    )
    Pattern.order(:id).last
  end

  before do
    # Use scifi era for instant fabrication in tests
    allow(EraService).to receive(:current_era).and_return(:scifi)
    allow(EraService).to receive(:scifi?).and_return(true)
    allow(EraService).to receive(:near_future?).and_return(false)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'in replicator room (universal facility)' do
      it 'fabricates item from pattern' do
        result = command.execute('fabricate silk dress')

        expect(result[:success]).to be true
        expect(result[:message]).to include('fabricate')
        expect(result[:message]).to include('Silk Dress')
      end

      it 'creates item in inventory' do
        expect { command.execute('fabricate silk dress') }
          .to change { character_instance.reload.objects.count }.by(1)
      end

      it 'returns fabricate data' do
        result = command.execute('fabricate silk dress')

        expect(result[:data][:action]).to eq('fabricate')
        expect(result[:data][:pattern_id]).to eq(pattern.id)
      end
    end

    context 'in room with shop' do
      let(:room) { create(:room, location: location, room_type: 'shop') }
      let!(:shop) { Shop.create(room: room, name: 'Test Shop') }

      it 'allows fabrication of clothing' do
        result = command.execute('fabricate silk dress')

        expect(result[:success]).to be true
      end
    end

    context 'in room with tailor' do
      let(:room) { create(:room, location: location, room_type: 'tailor') }

      it 'allows fabrication of clothing' do
        result = command.execute('fabricate silk dress')

        expect(result[:success]).to be true
      end
    end

    context 'in tutorial room' do
      let(:room) { create(:room, location: location, tutorial_room: true) }

      it 'allows fabrication in tutorial rooms' do
        result = command.execute('fabricate silk dress')
        expect(result[:success]).to be true
      end
    end

    context 'without fabrication facility access' do
      let(:other_character) { create(:character, forename: 'Bob') }
      let(:room) { create(:room, location: location, owner_id: other_character.id) }

      it 'returns error' do
        result = command.execute('fabricate silk dress')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/fabrication facility|materializer|workshop/i)
      end
    end

    context 'with unknown pattern' do
      it 'returns error' do
        result = command.execute('fabricate golden armor')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have a pattern/i)
      end
    end

    context 'with empty input' do
      it 'shows pending orders message' do
        result = command.execute('fabricate')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/no pending fabrication orders/i)
        expect(result[:type]).to eq(:fabrication_orders)
      end
    end

    context 'with orders subcommand' do
      it 'shows pending orders' do
        result = command.execute('fabricate orders')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:fabrication_orders)
      end
    end

    context 'fabricating deck' do
      let!(:deck_pattern) do
        DeckPattern.create(
          name: 'Standard Playing Cards',
          creator: character,
          is_public: true
        )
      end

      let!(:cards) do
        (1..52).map do |i|
          Card.create(deck_pattern: deck_pattern, name: "Card #{i}", display_order: i)
        end
      end

      it 'creates deck from owned pattern' do
        result = command.execute('fabricate deck')

        expect(result[:success]).to be true
        expect(result[:message]).to include('conjure')
        expect(result[:message]).to include('52 cards')
      end

      it 'creates deck record' do
        expect { command.execute('fabricate deck') }
          .to change { Deck.count }.by(1)
      end
    end

    context 'with no deck patterns' do
      it 'returns error when fabricating deck' do
        result = command.execute('fabricate deck')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't own any deck patterns/i)
      end
    end
  end

  describe 'non-instant fabrication' do
    subject(:command) { described_class.new(character_instance) }

    let(:room) { create(:room, location: location, room_type: 'tailor') }

    before do
      # Use modern era for non-instant fabrication
      allow(EraService).to receive(:current_era).and_return(:modern)
      allow(EraService).to receive(:scifi?).and_return(false)
      allow(EraService).to receive(:near_future?).and_return(false)
    end

    it 'shows delivery options quickmenu' do
      result = command.execute('fabricate silk dress')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:quickmenu)
      expect(result[:data][:prompt]).to include('How would you like to receive')
    end
  end

  describe 'pickup order' do
    subject(:command) { described_class.new(character_instance) }

    let(:room) { create(:room, location: location, room_type: 'tailor') }

    before do
      allow(EraService).to receive(:current_era).and_return(:scifi)
    end

    it 'returns error when order not found' do
      result = command.execute('fabricate pickup 999')

      expect(result[:success]).to be false
      expect(result[:error]).to match(/not found/i)
    end

    context 'with a ready order' do
      let!(:order) do
        FabricationOrder.create(
          character_id: character.id,
          pattern_id: pattern.id,
          status: 'ready',
          delivery_method: 'pickup',
          fabrication_room_id: room.id
        )
      end

      it 'allows pickup of ready order' do
        result = command.execute('fabricate pickup 1')

        expect(result[:success]).to be true
        expect(result[:message]).to match(/collect/i)
      end
    end
  end

  describe 'admin access' do
    subject(:command) { described_class.new(character_instance) }

    let(:room) { create(:room, location: location) } # No special room type

    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'allows admin to fabricate anywhere' do
      result = command.execute('fabricate silk dress')

      expect(result[:success]).to be true
    end
  end
end
