# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe TaxiService do
  let(:location) { create(:location) }
  let(:street_room) { create(:room, name: 'Main Street', short_description: 'A busy street.', location: location, room_type: 'street') }
  let(:indoor_room) { create(:room, name: 'Coffee Shop', short_description: 'A cozy coffee shop.', location: location, room_type: 'building') }
  let(:destination_room) { create(:room, name: 'Central Park', short_description: 'A peaceful park.', location: location, room_type: 'garden') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: street_room) }

  # Get the universe from the location's zone's world for currency creation
  let(:universe) { location.zone.world.universe }

  # Helper to set the era
  def set_era(era)
    GameSetting.set('time_period', era.to_s, type: 'string')
  end

  before do
    character_instance
    destination_room
  end

  describe '.available?' do
    it 'returns false for medieval era' do
      set_era(:medieval)
      expect(described_class.available?).to be false
    end

    it 'returns true for gaslight era' do
      set_era(:gaslight)
      expect(described_class.available?).to be true
    end

    it 'returns true for modern era' do
      set_era(:modern)
      expect(described_class.available?).to be true
    end

    it 'returns true for near_future era' do
      set_era(:near_future)
      expect(described_class.available?).to be true
    end

    it 'returns true for scifi era' do
      set_era(:scifi)
      expect(described_class.available?).to be true
    end
  end

  describe '.taxi_type' do
    it 'returns nil for medieval era' do
      set_era(:medieval)
      expect(described_class.taxi_type).to be_nil
    end

    it 'returns :carriage for gaslight era' do
      set_era(:gaslight)
      expect(described_class.taxi_type).to eq(:carriage)
    end

    it 'returns :rideshare for modern era' do
      set_era(:modern)
      expect(described_class.taxi_type).to eq(:rideshare)
    end

    it 'returns :autocab for near_future era' do
      set_era(:near_future)
      expect(described_class.taxi_type).to eq(:autocab)
    end

    it 'returns :hovertaxi for scifi era' do
      set_era(:scifi)
      expect(described_class.taxi_type).to eq(:hovertaxi)
    end
  end

  describe '.taxi_name' do
    it 'returns hansom cab for gaslight era' do
      set_era(:gaslight)
      expect(described_class.taxi_name).to eq('hansom cab')
    end

    it 'returns ride for modern era' do
      set_era(:modern)
      expect(described_class.taxi_name).to eq('ride')
    end

    it 'returns autocab for near_future era' do
      set_era(:near_future)
      expect(described_class.taxi_name).to eq('autocab')
    end

    it 'returns hover taxi for scifi era' do
      set_era(:scifi)
      expect(described_class.taxi_name).to eq('hover taxi')
    end
  end

  describe '.call_taxi' do
    context 'in medieval era' do
      before { set_era(:medieval) }

      it 'returns an error since taxis are not available' do
        result = described_class.call_taxi(character_instance)

        expect(result[:success]).to be false
        expect(result[:error]).to include('no taxi service')
      end
    end

    context 'in modern era' do
      before { set_era(:modern) }

      context 'when outdoors on a street' do
        it 'successfully calls a taxi' do
          result = described_class.call_taxi(character_instance)

          expect(result[:success]).to be true
          expect(result[:message]).to include('rideshare')
          expect(result[:data][:taxi_type]).to eq(:rideshare)
        end
      end

      context 'when indoors in modern era (app-based)' do
        before do
          character_instance.update(current_room: indoor_room)
        end

        it 'successfully calls a taxi since apps work anywhere' do
          result = described_class.call_taxi(character_instance)

          expect(result[:success]).to be true
        end
      end
    end

    context 'in gaslight era' do
      before { set_era(:gaslight) }

      context 'when outdoors on a street' do
        it 'successfully calls a hansom cab' do
          result = described_class.call_taxi(character_instance)

          expect(result[:success]).to be true
          expect(result[:message]).to include('hansom cab')
          expect(result[:data][:taxi_type]).to eq(:carriage)
        end
      end

      context 'when indoors' do
        before do
          character_instance.update(current_room: indoor_room)
        end

        it 'cannot call a cab from indoors (no apps)' do
          result = described_class.call_taxi(character_instance)

          expect(result[:success]).to be false
          expect(result[:error]).to include("can't call")
        end
      end
    end

    context 'in scifi era' do
      before { set_era(:scifi) }

      it 'calls a hover taxi' do
        result = described_class.call_taxi(character_instance)

        expect(result[:success]).to be true
        expect(result[:message]).to include('hover taxi')
        expect(result[:data][:taxi_type]).to eq(:hovertaxi)
      end
    end

    context 'without a current room' do
      before { set_era(:modern) }

      it 'returns an error' do
        # Use stub since model validation requires current_room_id
        allow(character_instance).to receive(:current_room).and_return(nil)

        result = described_class.call_taxi(character_instance)

        expect(result[:success]).to be false
        expect(result[:error]).to include('somewhere')
      end
    end
  end

  describe '.board_taxi' do
    before { set_era(:modern) }

    context 'with a valid destination' do
      let(:currency) { Currency.create(name: 'Dollar', symbol: '$', universe: universe, is_primary: true) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 1000
        )
      end

      it 'successfully travels to the destination' do
        result = described_class.board_taxi(character_instance, 'Central Park')

        expect(result[:success]).to be true
        expect(result[:data][:destination]).to eq('Central Park')
        expect(result[:message]).to include('Central Park')
      end

      it 'deducts the fare' do
        initial_balance = wallet.balance
        described_class.board_taxi(character_instance, 'Central Park')

        wallet.refresh
        expect(wallet.balance).to be < initial_balance
      end

      it 'moves the character to the destination room' do
        described_class.board_taxi(character_instance, 'Central Park')

        character_instance.refresh
        expect(character_instance.current_room_id).to eq(destination_room.id)
      end
    end

    context 'with an unknown destination' do
      it 'returns an error' do
        result = described_class.board_taxi(character_instance, 'Nonexistent Place')

        expect(result[:success]).to be false
        expect(result[:error]).to include("doesn't know where")
      end
    end

    context 'when player cannot afford the fare' do
      let(:currency) { Currency.create(name: 'Dollar', symbol: '$', universe: universe, is_primary: true) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 1 # Very low balance
        )
      end

      it 'returns an error about insufficient funds' do
        result = described_class.board_taxi(character_instance, 'Central Park')

        expect(result[:success]).to be false
        expect(result[:error]).to include("can't afford")
      end
    end

    context 'with an empty destination' do
      it 'returns an error' do
        result = described_class.board_taxi(character_instance, '')

        expect(result[:success]).to be false
        expect(result[:error]).to include("doesn't know where")
      end
    end
  end
end
