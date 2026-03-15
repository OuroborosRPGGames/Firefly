# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Dress, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:alice) { create(:character, forename: 'Alice') }
  let(:bob) { create(:character, forename: 'Bob') }
  let(:alice_instance) { create(:character_instance, character: alice, current_room: room, reality: reality, online: true) }
  let(:bob_instance) { create(:character_instance, character: bob, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(alice_instance) }

    context 'with no argument' do
      it 'returns error' do
        result = command.execute('dress')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/dress whom/i)
      end
    end

    context 'with target not in room' do
      let!(:jacket) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: alice_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'returns error' do
        result = command.execute('dress Charlie with jacket')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not here/i)
      end
    end

    context 'with valid target but no item specified' do
      before { bob_instance } # Ensure Bob is in the room

      it 'returns error requesting item' do
        result = command.execute('dress Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/dress.*with what/i)
      end
    end

      context 'with valid target and item' do
        let!(:jacket) do
          Item.create(
            name: 'Leather Jacket',
          character_instance: alice_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
        end

        before { bob_instance } # Ensure Bob is in the room

        context 'when item is a piercing' do
          let!(:stud) do
            Item.create(
              name: 'Silver Stud',
              character_instance: alice_instance,
              quantity: 1,
              condition: 'good',
              is_jewelry: true,
              is_piercing: true,
              worn: false
            )
          end

          before do
            InteractionPermissionService.grant_temporary_permission(
              bob_instance,  # granter (target)
              alice_instance,  # grantee (actor)
              'dress',
              room_id: room.id
            )
          end

          it 'fails when the target has no pierced positions' do
            result = command.execute('dress Bob with silver stud')

            expect(result[:success]).to be false
            expect(result[:error]).to include('piercing holes')
            expect(stud.reload.character_instance_id).to eq(alice_instance.id)
            expect(stud.reload.worn).to be false
          end

          it 'auto-wears on the only pierced position' do
            bob_instance.add_piercing_position!('left ear')

            result = command.execute('dress Bob with silver stud')

            expect(result[:success]).to be true
            expect(stud.reload.character_instance_id).to eq(bob_instance.id)
            expect(stud.reload.worn).to be true
            expect(stud.reload.piercing_position).to eq('left ear')
          end
        end

        context 'without permission' do
          it 'prompts target for permission' do
            result = command.execute('dress Bob with jacket')

          expect(result[:success]).to be true
          expect(result[:message]).to include('permission')
          expect(result[:data][:awaiting_consent]).to be true
        end
      end

      context 'with existing permission' do
        before do
          # Simulate granted permission using unified service
          InteractionPermissionService.grant_temporary_permission(
            bob_instance,  # granter (target)
            alice_instance,  # grantee (actor)
            'dress',
            room_id: room.id
          )
        end

        it 'dresses the target' do
          result = command.execute('dress Bob with jacket')

          expect(result[:success]).to be true
          expect(result[:message]).to include('dress')
          expect(result[:message]).to include('Bob')
          expect(result[:message]).to include('Leather Jacket')
          expect(jacket.reload.character_instance_id).to eq(bob_instance.id)
          expect(jacket.reload.worn).to be true
        end
      end

      context 'when target is wearing the item' do
        let!(:alice_shirt) do
          Item.create(
            name: 'Blue Shirt',
            character_instance: alice_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: false
          )
        end

        let!(:bob_shirt) do
          Item.create(
            name: 'Blue Shirt',
            character_instance: bob_instance,
            quantity: 1,
            condition: 'good',
            is_clothing: true,
            worn: true
          )
        end

        before do
          # Simulate granted permission using unified service
          InteractionPermissionService.grant_temporary_permission(
            bob_instance,  # granter (target)
            alice_instance,  # grantee (actor)
            'dress',
            room_id: room.id
          )
        end

        it 'returns error about target already wearing item' do
          result = command.execute('dress Bob with shirt')

          expect(result[:success]).to be false
          expect(result[:error]).to match(/already wearing/i)
        end
      end
    end

    context 'trying to dress self' do
      let!(:jacket) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: alice_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'suggests using wear instead' do
        result = command.execute('dress self with jacket')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/wear/i)
      end
    end
  end
end
