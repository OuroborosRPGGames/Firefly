# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Taxi, type: :command do
  let(:location) { create(:location) }
  # Get the universe from the location chain (location → zone → world → universe)
  let(:universe) { location.zone.world.universe }

  let(:street_room) do
    create(:room,
           name: 'Main Street',
           short_description: 'A busy street.',
           location: location,
           room_type: 'street')
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Rider', surname: 'Test', user: user) }

  # Give destination_room an owner so it's not a "public" destination
  # This ensures the taxi quickmenu doesn't show it by default
  let(:destination_room) do
    create(:room,
           name: 'Central Park',
           short_description: 'A peaceful park.',
           location: location,
           room_type: 'garden',  # 'park' is not a valid room_type, use 'garden' instead
           owner_id: character.id)  # Make it owned so taxi doesn't list as public destination
  end

  let(:character_instance) do
    create(:character_instance, character: character, current_room: street_room)
  end

  # Currency must be linked to the same universe as the location
  let(:currency) { create(:currency, name: 'Dollar', symbol: '$', is_primary: true, universe: universe) }
  let!(:wallet) do
    Wallet.create(
      character_instance: character_instance,
      currency: currency,
      balance: 1000
    )
  end

  # Helper to set the era
  def set_era(era)
    GameSetting.set('time_period', era.to_s, type: 'string')
  end

  before do
    destination_room
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'in medieval era (no taxis)' do
      before { set_era(:medieval) }

      it 'returns an error about no taxi service' do
        result = command.execute('taxi')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no taxi service')
      end
    end

    context 'in modern era' do
      before { set_era(:modern) }

      context 'calling a taxi without destination' do
        it 'successfully calls a taxi' do
          result = command.execute('taxi')

          expect(result[:success]).to be true
          expect(result[:message]).to include('rideshare')
        end
      end

      context 'with destination using "to" prefix' do
        it 'travels to the destination' do
          result = command.execute('taxi to Central Park')

          puts "DEBUG: #{result.inspect}" unless result[:success]
          expect(result[:success]).to be true
          expect(result[:data][:action]).to eq('taxi_travel')
        end

        it 'moves the character to the destination' do
          command.execute('taxi to Central Park')

          character_instance.refresh
          expect(character_instance.current_room_id).to eq(destination_room.id)
        end
      end

      context 'with destination without "to" prefix' do
        it 'treats input as destination' do
          result = command.execute('taxi Central Park')

          expect(result[:success]).to be true
        end
      end

      context 'with unknown destination' do
        it 'returns an error' do
          result = command.execute('taxi to Unknown Place')

          expect(result[:success]).to be false
          expect(result[:error]).to include("doesn't know where")
        end
      end
    end

    context 'in gaslight era' do
      before { set_era(:gaslight) }

      it 'calls a hansom cab' do
        result = command.execute('taxi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('hansom cab')
      end
    end

    context 'in near_future era' do
      before { set_era(:near_future) }

      it 'calls an autocab' do
        result = command.execute('taxi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('autonomous vehicle')
      end
    end

    context 'in scifi era' do
      before { set_era(:scifi) }

      it 'calls a hover taxi' do
        result = command.execute('taxi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('hover taxi')
      end
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('taxi')
    end

    it 'has rideshare aliases' do
      aliases = described_class.alias_names
      expect(aliases).to include('hail', 'rideshare', 'uber', 'lyft', 'autocab')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end
  end
end
