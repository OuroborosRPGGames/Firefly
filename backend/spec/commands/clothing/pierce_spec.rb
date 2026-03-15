# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Pierce, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:alice) { create(:character, forename: 'Alice') }
  let(:alice_instance) { create(:character_instance, character: alice, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(alice_instance) }

    context 'with no input' do
      it 'returns error' do
        result = command.execute('pierce')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/pierce what/i)
      end
    end

    context 'without specifying an item' do
      it 'returns error' do
        result = command.execute('pierce my left ear')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/specify what piercing/i)
      end
    end

    context 'with no piercing items in inventory' do
      it 'returns error' do
        result = command.execute('pierce my left ear with silver stud')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have any piercing jewelry/i)
      end
    end

    context 'with piercing item in inventory' do
      let!(:silver_stud) do
        Item.create(
          name: 'Silver Stud',
          character_instance: alice_instance,
          is_piercing: true,
          is_jewelry: true,
          worn: false
        )
      end

      it 'pierces and wears the item at specified position' do
        result = command.execute('pierce my left ear with silver stud')

        expect(result[:success]).to be true
        expect(result[:message]).to include('left ear')
        expect(result[:message]).to include('pierce')

        # Check the item is now worn at the position
        silver_stud.reload
        expect(silver_stud.worn).to be true
        expect(silver_stud.piercing_position).to eq('left ear')

        # Check the position is now in piercing_positions
        alice_instance.reload
        expect(alice_instance.pierced_at?('left ear')).to be true
      end

      it 'returns correct data' do
        result = command.execute('pierce my left ear with silver stud')

        expect(result[:data][:action]).to eq('pierce')
        expect(result[:data][:item_id]).to eq(silver_stud.id)
        expect(result[:data][:position]).to eq('left ear')
        expect(result[:data][:new_piercing]).to be true
      end

      context 'when already pierced at that position' do
        before do
          alice_instance.add_piercing_position!('left ear')
        end

        it 'wears the piercing without creating new hole' do
          result = command.execute('pierce my left ear with silver stud')

          expect(result[:success]).to be true
          expect(result[:message]).to include('put')
          expect(result[:data][:new_piercing]).to be false
        end
      end

      context 'when another piercing is already worn at that position' do
        let!(:gold_ring) do
          Item.create(
            name: 'Gold Ring',
            character_instance: alice_instance,
            is_piercing: true,
            is_jewelry: true,
            worn: true,
            piercing_position: 'left ear'
          )
        end

        before do
          alice_instance.add_piercing_position!('left ear')
        end

        it 'returns error about existing piercing' do
          result = command.execute('pierce my left ear with silver stud')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/already have a piercing worn/i)
        end
      end
    end

    context 'with wrong item name' do
      let!(:silver_stud) do
        Item.create(
          name: 'Silver Stud',
          character_instance: alice_instance,
          is_piercing: true,
          is_jewelry: true,
          worn: false
        )
      end

      it 'returns error with available piercings' do
        result = command.execute('pierce my left ear with gold ring')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have 'gold ring'")
        expect(result[:error]).to include('Silver Stud')
      end
    end
  end
end
