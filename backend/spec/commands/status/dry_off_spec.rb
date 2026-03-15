# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Status::DryOff, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true, wetness: 50) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when wet with towel' do
      let!(:towel) do
        Item.create(
          name: 'Fluffy Towel',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'dries off the character' do
        expect(character_instance.wet?).to be true

        result = command.execute('dry off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('dry off')
        expect(result[:message]).to include('Fluffy Towel')
        expect(character_instance.reload.wet?).to be false
      end

      it 'accepts adverbs' do
        result = command.execute('dry off quickly')

        expect(result[:success]).to be true
        expect(result[:message]).to include('quickly')
      end

      it 'returns correct data' do
        result = command.execute('dry off')

        expect(result[:data][:action]).to eq('dry_off')
        expect(result[:data][:towel_name]).to eq('Fluffy Towel')
      end
    end

    context 'when not wet' do
      before { character_instance.update(wetness: 0) }

      let!(:towel) do
        Item.create(
          name: 'Towel',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'returns error' do
        result = command.execute('dry off')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not wet')
      end
    end

    context 'when wet without towel' do
      it 'returns error' do
        result = command.execute('dry off')

        expect(result[:success]).to be false
        expect(result[:error]).to include('towel')
      end
    end

    context 'with aliases' do
      let!(:towel) do
        Item.create(
          name: 'Towel',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'works with dryoff alias' do
        command_class, _words = Commands::Base::Registry.find_command('dryoff')
        expect(command_class).to eq(Commands::Status::DryOff)
      end

      it 'works with dry alias' do
        command_class, _words = Commands::Base::Registry.find_command('dry')
        expect(command_class).to eq(Commands::Status::DryOff)
      end
    end
  end
end
