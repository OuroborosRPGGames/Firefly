# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Unzip, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no argument' do
      it 'returns error' do
        result = command.execute('unzip')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/unzip what/i)
      end
    end

    context 'with valid zipped item' do
      let!(:jacket) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          zipped: true
        )
      end

      it 'unzips the item' do
        result = command.execute('unzip jacket')

        expect(result[:success]).to be true
        expect(result[:message]).to include('unzip')
        expect(result[:message]).to include('Leather Jacket')
        expect(jacket.reload.zipped).to be false
      end

      it 'returns unzip data' do
        result = command.execute('unzip jacket')

        expect(result[:data][:action]).to eq('unzip')
        expect(result[:data][:item_name]).to eq('Leather Jacket')
      end
    end

    context 'with already unzipped item' do
      let!(:unzipped_item) do
        Item.create(
          name: 'Open Hoodie',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          zipped: false
        )
      end

      it 'returns error' do
        result = command.execute('unzip hoodie')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/already unzipped|already unbuttoned/i)
      end
    end

    context 'with non-worn item' do
      let!(:inventory_item) do
        Item.create(
          name: 'Unworn Coat',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false,
          zipped: true
        )
      end

      it 'returns error' do
        result = command.execute('unzip coat')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with multiple items' do
      let!(:jacket) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          zipped: true
        )
      end

      let!(:hoodie) do
        Item.create(
          name: 'Black Hoodie',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          zipped: true
        )
      end

      let!(:shirt) do
        Item.create(
          name: 'Dress Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          zipped: true
        )
      end

      it 'unzips multiple comma-separated items' do
        result = command.execute('unzip jacket, hoodie, shirt')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
        expect(result[:message]).to include('Black Hoodie')
        expect(result[:message]).to include('Dress Shirt')
        expect(jacket.reload.zipped).to be false
        expect(hoodie.reload.zipped).to be false
        expect(shirt.reload.zipped).to be false
      end

      it 'unzips multiple and-separated items' do
        result = command.execute('unzip jacket and hoodie')

        expect(result[:success]).to be true
        expect(jacket.reload.zipped).to be false
        expect(hoodie.reload.zipped).to be false
      end

      it 'returns data with all items' do
        result = command.execute('unzip jacket, hoodie')

        expect(result[:data][:action]).to eq('unzip')
        expect(result[:data][:items]).to contain_exactly('Leather Jacket', 'Black Hoodie')
      end

      it 'handles partial failures gracefully' do
        hoodie.update(zipped: false) # Already unzipped

        result = command.execute('unzip jacket, hoodie, shirt')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
        expect(result[:message]).to include('Dress Shirt')
        expect(result[:message]).to include('Could not unzip')
        expect(result[:message]).to include('already unzipped')
        expect(jacket.reload.zipped).to be false
        expect(shirt.reload.zipped).to be false
      end
    end
  end
end
