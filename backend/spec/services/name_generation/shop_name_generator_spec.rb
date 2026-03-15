# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::ShopNameGenerator do
  let(:generator) { described_class.new }

  describe '#generate' do
    context 'with default parameters' do
      it 'returns a ShopResult' do
        result = generator.generate
        expect(result).to be_a(NameGeneration::ShopResult)
      end

      it 'generates a shop name' do
        result = generator.generate
        expect(result.name).to be_a(String)
        expect(result.name).not_to be_empty
      end

      it 'includes metadata' do
        result = generator.generate
        expect(result.metadata).to be_a(Hash)
        expect(result.metadata[:shop_type]).to eq(:tavern)
        expect(result.metadata[:setting]).to eq(:earth_modern)
      end
    end

    context 'with different shop types' do
      described_class::SHOP_TYPES.each do |shop_type|
        it "generates names for #{shop_type} shop type" do
          result = generator.generate(shop_type: shop_type)
          expect(result.metadata[:shop_type]).to eq(shop_type)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with different settings' do
      described_class::VALID_SETTINGS.each do |setting|
        it "generates names for #{setting} setting" do
          result = generator.generate(setting: setting)
          expect(result.metadata[:setting]).to eq(setting)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with different templates' do
      described_class::TEMPLATE_PATTERNS.each do |template|
        it "generates names using #{template} template" do
          result = generator.generate(template: template)
          expect(result.metadata[:template]).to eq(template)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with random template' do
      it 'selects a valid template' do
        result = generator.generate(template: :random)
        expect(described_class::TEMPLATE_PATTERNS).to include(result.metadata[:template])
      end
    end
  end

  describe '#generate_batch' do
    it 'generates multiple shop names' do
      results = generator.generate_batch(5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::ShopResult))
    end

    it 'passes options to each generation' do
      results = generator.generate_batch(3, shop_type: :blacksmith, setting: :fictional_historic)
      results.each do |result|
        expect(result.metadata[:shop_type]).to eq(:blacksmith)
        expect(result.metadata[:setting]).to eq(:fictional_historic)
      end
    end
  end

  describe 'template patterns' do
    context 'adjective_noun template' do
      it 'generates "The {adjective} {noun}" names' do
        10.times do
          result = generator.generate(template: :adjective_noun)
          expect(result.name).to start_with('The ')
        end
      end
    end

    context 'owner_shop template' do
      it 'generates "{owner}\'s {shop_type}" names' do
        10.times do
          result = generator.generate(template: :owner_shop)
          expect(result.name).to include("'s ")
        end
      end
    end

    context 'noun_and_noun template' do
      it 'generates "The {noun} and {noun}" names' do
        10.times do
          result = generator.generate(template: :noun_and_noun)
          expect(result.name).to match(/The .+ and .+/)
        end
      end
    end

    context 'number_noun template' do
      it 'generates "{number} {noun}s" names' do
        10.times do
          result = generator.generate(template: :number_noun)
          expect(result.name).to match(/(Three|Four|Five|Seven|Nine|Twelve) \w+s/)
        end
      end
    end
  end

  describe 'shop types' do
    context 'tavern' do
      it 'generates appropriate tavern names' do
        10.times do
          result = generator.generate(shop_type: :tavern, template: :owner_shop)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'blacksmith' do
      it 'generates appropriate blacksmith names' do
        10.times do
          result = generator.generate(shop_type: :blacksmith, template: :owner_shop)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'magic shop' do
      it 'generates appropriate magic shop names' do
        10.times do
          result = generator.generate(shop_type: :magic, setting: :fictional_historic)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'tech shop' do
      it 'generates appropriate tech shop names' do
        10.times do
          result = generator.generate(shop_type: :tech, setting: :earth_future)
          expect(result.name).not_to be_empty
        end
      end
    end
  end

  describe 'setting-specific names' do
    context 'historic settings' do
      it 'generates period-appropriate names' do
        20.times do
          result = generator.generate(setting: :earth_historic, shop_type: :tavern)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'fantasy settings' do
      it 'generates fantasy-style names' do
        20.times do
          result = generator.generate(setting: :fictional_historic, shop_type: :magic)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'sci-fi settings' do
      it 'generates sci-fi style names' do
        20.times do
          result = generator.generate(setting: :earth_future, shop_type: :tech)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'alien settings' do
      it 'generates alien-style names' do
        20.times do
          result = generator.generate(setting: :fictional_future_alien, shop_type: :tavern)
          expect(result.name).not_to be_empty
        end
      end
    end
  end

  describe 'consistency and randomness' do
    it 'generates different names on successive calls' do
      names = 30.times.map { generator.generate.name }
      unique_names = names.uniq

      # Should have some variety
      expect(unique_names.length).to be >= 3
    end

    it 'produces valid names every time' do
      100.times do
        result = generator.generate
        expect(result.name).to be_a(String)
        expect(result.name.length).to be >= 5
      end
    end
  end

  describe 'invalid input handling' do
    it 'falls back to earth_modern for unknown settings' do
      result = generator.generate(setting: :unknown_setting)
      expect(result.metadata[:setting]).to eq(:earth_modern)
    end

    it 'falls back to general_store for unknown shop types' do
      result = generator.generate(shop_type: :unknown_type)
      expect(result.metadata[:shop_type]).to eq(:general_store)
    end
  end
end
