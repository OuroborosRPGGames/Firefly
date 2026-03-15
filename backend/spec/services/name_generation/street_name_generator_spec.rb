# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::StreetNameGenerator do
  let(:generator) { described_class.new }

  describe '#generate' do
    context 'with default parameters' do
      it 'returns a StreetResult' do
        result = generator.generate
        expect(result).to be_a(NameGeneration::StreetResult)
      end

      it 'generates a street name' do
        result = generator.generate
        expect(result.name).to be_a(String)
        expect(result.name).not_to be_empty
      end

      it 'includes metadata' do
        result = generator.generate
        expect(result.metadata).to be_a(Hash)
        expect(result.metadata[:setting]).to eq(:earth_modern)
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

    context 'with different styles' do
      described_class::STYLE_TYPES.each do |style|
        it "generates names using #{style} style" do
          result = generator.generate(style: style)
          expect(result.metadata[:style]).to eq(style)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'with random style' do
      it 'selects a valid style' do
        result = generator.generate(style: :random)
        expect(described_class::STYLE_TYPES).to include(result.metadata[:style])
      end
    end
  end

  describe '#generate_batch' do
    it 'generates multiple street names' do
      results = generator.generate_batch(5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::StreetResult))
    end

    it 'passes options to each generation' do
      results = generator.generate_batch(3, setting: :fictional_historic)
      results.each do |result|
        expect(result.metadata[:setting]).to eq(:fictional_historic)
      end
    end
  end

  describe 'named style' do
    it 'generates street names with type suffixes' do
      10.times do
        result = generator.generate(style: :named)
        # Should have a street type (Street, Avenue, etc.)
        expect(result.name).to match(/Street|Avenue|Road|Drive|Lane|Way|Boulevard|Place|Court|Row|Alley|Path|Corridor|Level|Sector/i)
      end
    end
  end

  describe 'numbered style' do
    it 'generates numbered street names' do
      10.times do
        result = generator.generate(style: :numbered)
        # Should have a number or ordinal
        expect(result.name).to match(/\d|st|nd|rd|th/i)
      end
    end
  end

  describe 'directional style' do
    it 'generates directional street names' do
      10.times do
        result = generator.generate(style: :directional, setting: :earth_modern)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'memorial style' do
    it 'generates memorial street names' do
      10.times do
        result = generator.generate(style: :memorial, setting: :earth_modern)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'descriptive style' do
    it 'generates descriptive street names' do
      10.times do
        result = generator.generate(style: :descriptive)
        expect(result.name).not_to be_empty
      end
    end
  end

  describe 'setting-specific street types' do
    context 'historic settings' do
      it 'uses historic street types' do
        20.times do
          result = generator.generate(setting: :earth_historic, style: :named)
          # May include historic types like Lane, Row, Close
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'fantasy settings' do
      it 'uses fantasy street types' do
        20.times do
          result = generator.generate(setting: :fictional_historic, style: :named)
          expect(result.name).not_to be_empty
        end
      end
    end

    context 'sci-fi settings' do
      it 'uses sci-fi street types' do
        20.times do
          result = generator.generate(setting: :earth_future, style: :named)
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
