# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::Buy, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, room_type: 'shop') }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  let(:currency) do
    Currency.create(
      universe: universe,
      name: 'Gold',
      symbol: 'G',
      decimal_places: 0,
      is_primary: true
    )
  end

  let(:unified_type) do
    # Use raw DB insert to bypass Sequel column caching
    DB[:unified_object_types].insert(
      name: 'Weapon',
      category: 'Sword',
      created_at: Time.now,
      updated_at: Time.now
    )
    UnifiedObjectType.order(:id).last
  end
  let(:pattern) do
    # Use raw DB insert for Pattern as well
    DB[:patterns].insert(
      description: 'Steel Sword',
      unified_object_type_id: unified_type.id,
      price: 50,
      created_at: Time.now,
      updated_at: Time.now
    )
    Pattern.order(:id).last
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with shop and sufficient wallet funds' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'purchases item successfully' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Steel Sword')
        expect(result[:message]).to include('G50')
      end

      it 'deducts money from wallet' do
        command.execute('buy steel sword')

        expect(wallet.reload.balance).to eq(50)
      end

      it 'creates item in inventory' do
        expect { command.execute('buy steel sword') }
          .to change { character_instance.reload.objects.count }.by(1)
      end

      it 'returns success with buy message' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('You buy Steel Sword')
      end
    end

    context 'with bank funds (non-cash shop)' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop', cash_shop: false) }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 100
        )
      end

      it 'uses bank funds first' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        expect(bank_account.reload.balance).to eq(50)
      end

      it 'uses wallet when bank insufficient' do
        bank_account.update(balance: 30)
        Wallet.create(character_instance: character_instance, currency: currency, balance: 50)

        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        expect(bank_account.reload.balance).to eq(0)
        wallet = Wallet.first(character_instance_id: character_instance.id)
        expect(wallet.balance).to eq(30)
      end
    end

    context 'with cash-only shop' do
      let!(:shop) { Shop.create(room: room, name: 'Street Vendor', cash_shop: true) }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 1000
        )
      end

      it 'ignores bank funds' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't afford/i)
        expect(bank_account.reload.balance).to eq(1000)
      end

      it 'uses wallet only' do
        Wallet.create(character_instance: character_instance, currency: currency, balance: 100)

        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
      end
    end

    context 'with limited stock' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: 2) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 200
        )
      end

      it 'decrements stock' do
        command.execute('buy steel sword')

        expect(shop_item.reload.stock).to eq(1)
      end

      it 'returns error when out of stock' do
        shop_item.update(stock: 0)

        result = command.execute('buy steel sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/out of stock/i)
      end

      it 'returns error when quantity exceeds stock' do
        result = command.execute('buy 5 steel sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/only 2.*in stock/i)
      end
    end

    context 'with quantity' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 200
        )
      end

      it 'purchases multiple items' do
        result = command.execute('buy 2 steel sword')

        expect(result[:success]).to be true
        expect(wallet.reload.balance).to eq(100)
        expect(character_instance.reload.objects.count).to eq(2)
      end

      it 'calculates total price correctly' do
        result = command.execute('buy 3 steel sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G150')
      end
    end

    context 'with free shop' do
      let!(:shop) { Shop.create(room: room, name: 'Tutorial Shop', free_items: true) }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }

      it 'gives items for free with buy message' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('You buy')
        expect(result[:message]).not_to include('take')
        expect(character_instance.reload.objects.count).to eq(1)
      end

      it 'does not require wallet' do
        expect(Wallet.where(character_instance_id: character_instance.id).count).to eq(0)

        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
      end
    end

    context 'with no shop' do
      it 'returns error' do
        result = command.execute('buy sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no shop here/i)
      end
    end

    context 'with item not in shop' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }

      it 'returns error' do
        result = command.execute('buy magic wand')

        expect(result[:success]).to be false
        # Empty shop returns "nothing for sale" message
        expect(result[:error]).to match(/nothing for sale/i)
      end
    end

    context 'with insufficient funds' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 10
        )
      end

      it 'returns error' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't afford/i)
      end
    end

    context 'with fuzzy matching' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('buy stee')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Steel Sword')
      end

      it 'matches short prefix' do
        result = command.execute('buy ste')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Steel Sword')
      end
    end

    context 'with buy by number' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'buys item by number' do
        result = command.execute('buy 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Steel Sword')
      end

      it 'returns error for invalid number' do
        result = command.execute('buy 99')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/invalid item number/i)
      end

      it 'returns error for zero' do
        result = command.execute('buy 0')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/invalid item number/i)
      end
    end

    context 'with empty input' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }

      it 'returns error when shop is empty' do
        result = command.execute('buy')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/nothing for sale/i)
      end
    end

    context 'shop listing after purchase' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 're-shows shop listing after successful purchase' do
        result = command.execute('buy steel sword')

        expect(result[:success]).to be true
        # Message should contain the buy confirmation and the shop listing
        expect(result[:message]).to include('You buy')
        expect(result[:message]).to include('<b>Weapon Shop</b>')
      end
    end

    context 'shop listing format' do
      let!(:shop) { Shop.create(room: room, name: 'Weapon Shop') }
      let!(:shop_item) { ShopItem.create(shop: shop, pattern: pattern, price: 50, stock: -1) }

      it 'shows items in ordered list with prices' do
        result = command.execute('buy')

        expect(result[:success]).to be true
        expect(result[:message]).to include('<b>Weapon Shop</b>')
        expect(result[:message]).to include('<ol')
        expect(result[:message]).to match(/\[.*50.*\]/)
      end

      it 'does not show tutorial hint for non-tutorial shop' do
        result = command.execute('buy')

        expect(result[:message]).not_to include('Type')
      end

      context 'with free shop' do
        let!(:free_shop) { shop.update(free_items: true); shop }

        it 'shows tutorial hint for free shop' do
          result = command.execute('buy')

          expect(result[:message]).to include('buy')
        end
      end
    end
  end
end
