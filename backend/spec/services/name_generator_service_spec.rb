# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneratorService do
  before(:each) do
    described_class.reset!
  end

  describe '.character' do
    it 'generates a character name' do
      result = described_class.character
      expect(result).to be_a(NameGeneration::NameResult)
      expect(result.forename).not_to be_empty
      expect(result.surname).not_to be_empty
      expect(result.full_name).not_to be_empty
    end

    it 'accepts gender option' do
      result = described_class.character(gender: :female)
      expect(result.metadata[:gender]).to eq(:female)
    end

    it 'accepts culture option' do
      result = described_class.character(culture: :nordic)
      expect(result.metadata[:culture]).to eq(:nordic)
    end

    it 'accepts setting option' do
      result = described_class.character(setting: :fictional_historic)
      expect(result.metadata[:setting]).to eq(:fictional_historic)
    end

    it 'accepts forename_only option' do
      result = described_class.character(forename_only: true)
      expect(result.forename).not_to be_empty
      expect(result.surname).to be_nil
    end
  end

  describe '.character_options' do
    it 'generates multiple character names' do
      results = described_class.character_options(count: 5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::NameResult))
    end

    it 'passes options to all generated names' do
      results = described_class.character_options(count: 3, gender: :male, culture: :western)
      results.each do |result|
        expect(result.metadata[:gender]).to eq(:male)
        expect(result.metadata[:culture]).to eq(:western)
      end
    end

    it 'defaults to 5 names' do
      results = described_class.character_options
      expect(results.length).to eq(5)
    end
  end

  describe '.city' do
    it 'generates a city name' do
      result = described_class.city
      expect(result).to be_a(NameGeneration::CityResult)
      expect(result.name).not_to be_empty
    end

    it 'accepts setting option' do
      result = described_class.city(setting: :fictional_historic)
      expect(result.metadata[:setting]).to eq(:fictional_historic)
    end

    it 'accepts pattern option' do
      result = described_class.city(pattern: :prefix_suffix)
      expect(result.metadata[:pattern]).to eq(:prefix_suffix)
    end

    it 'accepts size option' do
      result = described_class.city(size: :village)
      expect(result.metadata[:size]).to eq(:village)
    end
  end

  describe '.city_options' do
    it 'generates multiple city names' do
      results = described_class.city_options(count: 5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::CityResult))
    end
  end

  describe '.town' do
    it 'is an alias for city' do
      expect(described_class.method(:town)).to eq(described_class.method(:city))
    end
  end

  describe '.street' do
    it 'generates a street name' do
      result = described_class.street
      expect(result).to be_a(NameGeneration::StreetResult)
      expect(result.name).not_to be_empty
    end

    it 'accepts setting option' do
      result = described_class.street(setting: :earth_future)
      expect(result.metadata[:setting]).to eq(:earth_future)
    end

    it 'accepts style option' do
      result = described_class.street(style: :numbered)
      expect(result.metadata[:style]).to eq(:numbered)
    end
  end

  describe '.street_options' do
    it 'generates multiple street names' do
      results = described_class.street_options(count: 5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::StreetResult))
    end
  end

  describe '.shop' do
    it 'generates a shop name' do
      result = described_class.shop
      expect(result).to be_a(NameGeneration::ShopResult)
      expect(result.name).not_to be_empty
    end

    it 'accepts shop_type option' do
      result = described_class.shop(shop_type: :blacksmith)
      expect(result.metadata[:shop_type]).to eq(:blacksmith)
    end

    it 'accepts setting option' do
      result = described_class.shop(setting: :fictional_historic)
      expect(result.metadata[:setting]).to eq(:fictional_historic)
    end

    it 'accepts template option' do
      result = described_class.shop(template: :adjective_noun)
      expect(result.metadata[:template]).to eq(:adjective_noun)
    end
  end

  describe '.shop_options' do
    it 'generates multiple shop names' do
      results = described_class.shop_options(count: 5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::ShopResult))
    end

    it 'passes options to all generated names' do
      results = described_class.shop_options(count: 3, shop_type: :tavern, setting: :earth_historic)
      results.each do |result|
        expect(result.metadata[:shop_type]).to eq(:tavern)
        expect(result.metadata[:setting]).to eq(:earth_historic)
      end
    end
  end

  describe '.reset!' do
    it 'resets the generators' do
      # Generate some names to warm up the cache
      described_class.character
      described_class.city

      # Reset
      expect { described_class.reset! }.not_to raise_error

      # Should still work after reset
      result = described_class.character
      expect(result).to be_a(NameGeneration::NameResult)
    end
  end

  describe '.available_cultures' do
    it 'returns a list of cultures' do
      cultures = described_class.available_cultures
      expect(cultures).to be_an(Array)
      expect(cultures).to include(:western, :nordic, :elf, :alien)
    end
  end

  describe '.available_settings' do
    it 'returns a list of settings' do
      settings = described_class.available_settings
      expect(settings).to be_an(Array)
      expect(settings).to include(:earth_modern, :fictional_historic)
    end
  end

  describe '.available_shop_types' do
    it 'returns a list of shop types' do
      shop_types = described_class.available_shop_types
      expect(shop_types).to be_an(Array)
      expect(shop_types).to include(:tavern, :blacksmith, :magic)
    end
  end

  describe 'integration scenarios' do
    context 'generating a fantasy town' do
      it 'creates coherent fantasy-themed names' do
        city = described_class.city(setting: :fictional_historic, size: :town)
        street = described_class.street(setting: :fictional_historic)
        shop = described_class.shop(setting: :fictional_historic, shop_type: :tavern)

        expect(city.name).not_to be_empty
        expect(street.name).not_to be_empty
        expect(shop.name).not_to be_empty
      end
    end

    context 'generating a sci-fi colony' do
      it 'creates coherent sci-fi themed names' do
        city = described_class.city(setting: :fictional_future_human)
        street = described_class.street(setting: :fictional_future_human)
        shop = described_class.shop(setting: :fictional_future_human, shop_type: :tech)

        expect(city.name).not_to be_empty
        expect(street.name).not_to be_empty
        expect(shop.name).not_to be_empty
      end
    end

    context 'LLM selection workflow' do
      it 'provides multiple options for AI to choose from' do
        # This simulates the LLM workflow
        character_options = described_class.character_options(count: 5, gender: :female)
        city_options = described_class.city_options(count: 3)
        shop_options = described_class.shop_options(count: 3, shop_type: :tavern)

        expect(character_options.length).to eq(5)
        expect(city_options.length).to eq(3)
        expect(shop_options.length).to eq(3)

        # All should be unique
        character_names = character_options.map(&:full_name)
        expect(character_names.uniq.length).to be >= 3
      end
    end

    context 'anti-repetition system' do
      it 'reduces repetition across many generations' do
        # Generate many names
        names = 50.times.map { described_class.character.full_name }

        # Should have significant variety
        unique_names = names.uniq
        expect(unique_names.length).to be >= 20
      end
    end
  end
end
