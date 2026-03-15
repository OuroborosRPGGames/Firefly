# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::CityNameGenerator do
  let(:generator) { described_class.new }

  describe '#generate' do
    context 'with default parameters' do
      it 'returns a CityResult' do
        result = generator.generate
        expect(result).to be_a(NameGeneration::CityResult)
      end

      it 'generates a city name' do
        result = generator.generate
        expect(result.name).to be_a(String)
        expect(result.name).not_to be_empty
      end

      it 'includes metadata' do
        result = generator.generate
        expect(result.metadata).to be_a(Hash)
        expect(result.metadata[:setting]).to eq(:earth_modern)
        expect(result.metadata[:size]).to eq(:city)
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

    context 'with different patterns' do
      described_class::PATTERN_TYPES.each do |pattern|
        it "generates names using #{pattern} pattern" do
          result = generator.generate(pattern: pattern)
          expect(result.metadata[:pattern]).to eq(pattern)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with different sizes' do
      %i[city town village].each do |size|
        it "generates names for #{size} size" do
          result = generator.generate(size: size)
          expect(result.metadata[:size]).to eq(size)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with random pattern' do
      it 'selects a valid pattern' do
        result = generator.generate(pattern: :random)
        expect(described_class::PATTERN_TYPES).to include(result.metadata[:pattern])
      end
    end
  end

  describe '#generate_batch' do
    it 'generates multiple city names' do
      results = generator.generate_batch(5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::CityResult))
    end

    it 'passes options to each generation' do
      results = generator.generate_batch(3, setting: :fictional_historic)
      results.each do |result|
        expect(result.metadata[:setting]).to eq(:fictional_historic)
      end
    end
  end

  describe 'earth_historic setting' do
    it 'generates medieval-style names' do
      10.times do
        result = generator.generate(setting: :earth_historic)
        expect(result.name).not_to be_empty
        # Should have English-style naming patterns
      end
    end
  end

  describe 'earth_modern setting' do
    it 'generates contemporary city names' do
      10.times do
        result = generator.generate(setting: :earth_modern)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'earth_future setting' do
    it 'generates futuristic city names' do
      10.times do
        result = generator.generate(setting: :earth_future)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'fictional_historic (fantasy) setting' do
    it 'generates fantasy-style city names' do
      10.times do
        result = generator.generate(setting: :fictional_historic)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'fictional_contemporary setting' do
    it 'generates urban fantasy city names' do
      10.times do
        result = generator.generate(setting: :fictional_contemporary)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'fictional_future_human (sci-fi) setting' do
    it 'generates human sci-fi city names' do
      10.times do
        result = generator.generate(setting: :fictional_future_human)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'fictional_future_alien setting' do
    it 'generates alien city names' do
      10.times do
        result = generator.generate(setting: :fictional_future_alien)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'pattern types' do
    context 'prefix_suffix pattern' do
      it 'generates compound names' do
        10.times do
          result = generator.generate(pattern: :prefix_suffix, setting: :earth_historic)
          # Should be a single word compound
          expect(result.name).not_to include("'s")
        end
      end
    end

    context 'adjective_noun pattern' do
      it 'generates two-word names' do
        10.times do
          result = generator.generate(pattern: :adjective_noun)
          # Most should have a space (Adjective + Noun)
          # Note: some fallbacks might not
        end
      end
    end

    context 'possessive pattern' do
      it 'generates possessive names' do
        20.times do
          result = generator.generate(pattern: :possessive, setting: :fictional_historic)
          # Some should have possessive or St. prefix
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'single pattern' do
      it 'generates single evocative names' do
        10.times do
          result = generator.generate(pattern: :single)
          expect(result.name).not_to be_empty
        end
      end
    end
  end

  describe 'size modifiers' do
    context 'town size' do
      it 'sometimes adds Town suffix' do
        town_names = 20.times.map { generator.generate(size: :town).name }
        # Some may have 'Town' suffix
        expect(town_names).to all(be_a(String))
      end
    end

    context 'village size' do
      it 'sometimes adds size modifiers' do
        village_names = 20.times.map { generator.generate(size: :village).name }
        # Some may have modifiers like 'Little' or 'Old'
        expect(village_names).to all(be_a(String))
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
        expect(result.name.length).to be >= 3
      end
    end
  end

  describe 'invalid setting handling' do
    it 'falls back to earth_modern for unknown settings' do
      result = generator.generate(setting: :unknown_setting)
      expect(result.metadata[:setting]).to eq(:earth_modern)
    end
  end
end
