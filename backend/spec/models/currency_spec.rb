# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Currency do
  let(:universe) { create(:universe) }
  let(:currency) { create(:currency, universe: universe) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(currency).to be_valid
    end

    it 'requires universe_id' do
      currency = build(:currency, universe: nil)
      expect(currency).not_to be_valid
      expect(currency.errors[:universe_id]).to include('is not present')
    end

    it 'requires name' do
      currency = build(:currency, universe: universe, name: nil)
      expect(currency).not_to be_valid
    end

    it 'requires symbol' do
      currency = build(:currency, universe: universe, symbol: nil)
      expect(currency).not_to be_valid
    end

    it 'validates max length of name' do
      currency = build(:currency, universe: universe, name: 'x' * 51)
      expect(currency).not_to be_valid
    end

    it 'validates max length of symbol' do
      currency = build(:currency, universe: universe, symbol: 'x' * 11)
      expect(currency).not_to be_valid
    end

    it 'validates uniqueness of name within universe' do
      create(:currency, universe: universe, name: 'Gold')
      duplicate = build(:currency, universe: universe, name: 'Gold')
      expect(duplicate).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to universe' do
      expect(currency.universe).to eq(universe)
    end
  end

  describe 'before_save callbacks' do
    it 'sets decimal_places to 2 by default' do
      currency = Currency.create(universe_id: universe.id, name: 'Test', symbol: '$')
      expect(currency.decimal_places).to eq(2)
    end

    it 'sets is_primary to false by default' do
      currency = Currency.create(universe_id: universe.id, name: 'Test2', symbol: '$$')
      expect(currency.is_primary).to eq(false)
    end
  end

  describe '#format_amount' do
    context 'with decimal places' do
      it 'formats amount with decimal' do
        currency = create(:currency, universe: universe, symbol: '$', decimal_places: 2)
        expect(currency.format_amount(1050)).to eq('$10.50')
      end

      it 'formats small amounts' do
        currency = create(:currency, universe: universe, symbol: '$', decimal_places: 2)
        expect(currency.format_amount(5)).to eq('$0.05')
      end
    end

    context 'without decimal places' do
      it 'formats amount as integer' do
        currency = create(:currency, :whole_numbers, universe: universe, symbol: 'G')
        expect(currency.format_amount(100)).to eq('G100')
      end
    end
  end

  describe '.default_for' do
    context 'with a default currency' do
      let!(:default_currency) { create(:currency, :default, universe: universe) }
      let!(:other_currency) { create(:currency, universe: universe) }

      it 'returns the default currency' do
        expect(described_class.default_for(universe)).to eq(default_currency)
      end
    end

    context 'without a default currency' do
      let!(:first_currency) { create(:currency, universe: universe) }

      it 'returns the first currency' do
        expect(described_class.default_for(universe)).to eq(first_currency)
      end
    end

    context 'with no currencies' do
      it 'returns nil' do
        expect(described_class.default_for(universe)).to be_nil
      end
    end
  end
end
