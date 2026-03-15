# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::Shop, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['shop']).to eq(described_class)
    end
  end

  # ========================================
  # No Shop Tests
  # ========================================

  describe 'without a shop in room' do
    it 'returns error message' do
      result = subject.execute('shop')

      expect(result[:success]).to be false
      expect(result[:error] || result[:message]).to include("no shop here")
    end
  end

  # ========================================
  # Shop Menu Tests
  # ========================================

  describe 'with a shop in room' do
    let!(:shop) do
      Shop.create(
        room_id: room.id,
        name: 'Test Shop'
      )
    end

    describe 'shop (no args)' do
      it 'shows shop quickmenu' do
        result = subject.execute('shop')

        expect(result[:interaction_id]).not_to be_nil
      end
    end

    describe 'shop buy' do
      context 'with no items in shop' do
        it 'returns error for empty shop' do
          result = subject.execute('shop buy')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('nothing for sale')
        end
      end

      context 'with items in shop' do
        let(:weapon_type) { create(:unified_object_type, category: 'weapons') }
        let(:pattern) { create(:pattern, description: 'Test Sword', unified_object_type: weapon_type) }
        let!(:shop_item) do
          ShopItem.create(
            shop_id: shop.id,
            pattern_id: pattern.id,
            price: 100,
            stock: 5
          )
        end

        it 'shows buy menu when no item specified' do
          result = subject.execute('shop buy')

          expect(result[:interaction_id]).not_to be_nil
        end

        it 'returns error for item not in shop' do
          result = subject.execute('shop buy Nonexistent Item')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("doesn't sell")
        end

        context 'with currency and wallet' do
          let(:universe) { create(:universe) }
          let(:world) { create(:world, universe: universe) }
          let(:zone_with_world) { create(:zone, world: world) }
          let!(:currency) { create(:currency, universe: universe, is_primary: true, symbol: '$') }
          let!(:wallet) { create(:wallet, character_instance: character_instance, currency: currency, balance: 500) }

          before do
            # Set up the universe hierarchy: Room -> Location -> Zone -> World -> Universe
            location.update(zone: zone_with_world)
          end

          it 'successfully buys an item' do
            result = subject.execute('shop buy Test Sword')

            expect(result[:success]).to be true
            expect(result[:message]).to include('buy')
          end

          it 'deducts money from wallet' do
            initial_balance = wallet.balance
            subject.execute('shop buy Test Sword')

            expect(wallet.reload.balance).to eq(initial_balance - 100)
          end

          it 'decrements stock' do
            initial_stock = shop_item.stock
            subject.execute('shop buy Test Sword')

            expect(shop_item.reload.stock).to eq(initial_stock - 1)
          end

          it 'creates item in inventory' do
            expect {
              subject.execute('shop buy Test Sword')
            }.to change { character_instance.objects_dataset.count }.by(1)
          end

          it 'returns error when insufficient funds' do
            wallet.update(balance: 10)

            result = subject.execute('shop buy Test Sword')

            expect(result[:success]).to be false
            expect(result[:error] || result[:message]).to include("afford")
          end

          context 'with quantity' do
            it 'buys multiple items' do
              result = subject.execute('shop buy 2 Test Sword')

              expect(result[:success]).to be true
              expect(result[:data][:quantity]).to eq(2)
            end

            it 'returns error when not enough stock' do
              shop_item.update(stock: 1)

              result = subject.execute('shop buy 3 Test Sword')

              expect(result[:success]).to be false
              expect(result[:error] || result[:message]).to include('in stock')
            end
          end

          context 'with out of stock item' do
            before do
              shop_item.update(stock: 0)
            end

            it 'returns error' do
              result = subject.execute('shop buy Test Sword')

              expect(result[:success]).to be false
              expect(result[:error] || result[:message]).to include('out of stock')
            end
          end

          context 'with unlimited stock' do
            before do
              shop_item.update(stock: -1)
            end

            it 'allows purchase without decrementing stock' do
              result = subject.execute('shop buy Test Sword')

              expect(result[:success]).to be true
              expect(shop_item.reload.stock).to eq(-1)
            end
          end

          context 'with free items shop' do
            before do
              shop.update(free_items: true)
            end

            it 'allows free purchase with buy message' do
              wallet.update(balance: 0)

              result = subject.execute('shop buy Test Sword')

              expect(result[:success]).to be true
              expect(result[:message]).to include('You buy')
            end
          end

          context 'payment handling' do
            context 'with cash_shop' do
              before do
                shop.update(cash_shop: true)
                wallet.update(balance: 10)
              end

              it 'returns error when wallet insufficient' do
                result = subject.execute('shop buy Test Sword')

                expect(result[:success]).to be false
                expect(result[:error] || result[:message]).to include("afford")
              end
            end

            context 'with bank account' do
              let!(:bank_account) { create(:bank_account, character: character, currency: currency, balance: 1000) }

              before do
                wallet.update(balance: 10)
              end

              it 'uses bank account when wallet insufficient' do
                result = subject.execute('shop buy Test Sword')

                expect(result[:success]).to be true
              end

              it 'does not use bank account for cash_shop' do
                shop.update(cash_shop: true)

                result = subject.execute('shop buy Test Sword')

                expect(result[:success]).to be false
              end
            end
          end
        end
      end
    end

    describe 'shop list' do
      context 'with no items' do
        it 'returns error for empty shop' do
          result = subject.execute('shop list')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('nothing for sale')
        end
      end

      context 'with items' do
        let(:weapon_type) { create(:unified_object_type, category: 'weapons') }
        let(:pattern) { create(:pattern, description: 'Test Sword', unified_object_type: weapon_type) }
        let!(:shop_item) do
          ShopItem.create(
            shop_id: shop.id,
            pattern_id: pattern.id,
            price: 100,
            stock: 5
          )
        end

        it 'shows item list with numbered format' do
          result = subject.execute('shop list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Test Sword')
          expect(result[:message]).to include('<b>Test Shop</b>')
        end
      end
    end

    describe 'shop stock' do
      context 'as non-owner' do
        it 'returns error' do
          result = subject.execute('shop stock')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("don't own")
        end
      end

      context 'as owner' do
        before do
          # Make room owned by the character
          room.update(owner_id: character.id)
        end

        it 'shows stock management' do
          result = subject.execute('shop stock')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Stock Management')
        end
      end
    end

    describe 'shop add' do
      context 'as non-owner' do
        it 'returns error' do
          result = subject.execute('shop add 50 sword')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("don't own")
        end
      end

      context 'as owner' do
        before do
          room.update(owner_id: character.id)
        end

        it 'returns error with no arguments' do
          result = subject.execute('shop add')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('Add what?')
        end

        it 'returns error with invalid price' do
          result = subject.execute('shop add -10 sword')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('Invalid price')
        end

        it 'returns error when item not in inventory' do
          result = subject.execute('shop add 50 nonexistent')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("don't have")
        end
      end
    end

    describe 'shop remove' do
      context 'as non-owner' do
        it 'returns error' do
          result = subject.execute('shop remove sword')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("don't own")
        end
      end

      context 'as owner' do
        before do
          room.update(owner_id: character.id)
        end

        it 'returns error with no arguments' do
          result = subject.execute('shop remove')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('Remove what?')
        end

        context 'with item in shop' do
          let(:weapon_type) { create(:unified_object_type, category: 'weapons') }
          let(:pattern) { create(:pattern, description: 'Test Sword', unified_object_type: weapon_type) }
          let!(:shop_item) do
            ShopItem.create(
              shop_id: shop.id,
              pattern_id: pattern.id,
              price: 100,
              stock: 5
            )
          end

          it 'removes item from shop' do
            result = subject.execute('shop remove Test Sword')

            expect(result[:success]).to be true
            expect(result[:message]).to include('Removed')
            expect(ShopItem.where(shop_id: shop.id, pattern_id: pattern.id).count).to eq(0)
          end
        end

        it 'returns error when item not in shop' do
          result = subject.execute('shop remove nonexistent')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include("doesn't have")
        end
      end
    end
  end

  # ========================================
  # Alias Tests
  # ========================================

  describe 'aliases' do
    it 'command has browse alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('browse')
    end

    it 'command has store alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('store')
    end
  end
end
