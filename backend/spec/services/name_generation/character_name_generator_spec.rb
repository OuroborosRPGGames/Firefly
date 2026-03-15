# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::CharacterNameGenerator do
  let(:generator) { described_class.new }

  describe '#generate' do
    context 'with default parameters' do
      it 'returns a NameResult' do
        result = generator.generate
        expect(result).to be_a(NameGeneration::NameResult)
      end

      it 'generates a full name with forename and surname' do
        result = generator.generate
        expect(result.forename).to be_a(String)
        expect(result.forename).not_to be_empty
        expect(result.surname).to be_a(String)
        expect(result.surname).not_to be_empty
        expect(result.full_name).to eq("#{result.forename} #{result.surname}")
      end

      it 'includes metadata' do
        result = generator.generate
        expect(result.metadata).to be_a(Hash)
        expect(result.metadata[:culture]).to eq(:western)
        expect(result.metadata[:setting]).to eq(:earth_modern)
      end
    end

    context 'with gender parameter' do
      it 'generates male names' do
        result = generator.generate(gender: :male)
        expect(result.metadata[:gender]).to eq(:male)
        expect(result.forename).not_to be_empty
      end

      it 'generates female names' do
        result = generator.generate(gender: :female)
        expect(result.metadata[:gender]).to eq(:female)
        expect(result.forename).not_to be_empty
      end

      it 'handles :any gender by selecting randomly' do
        result = generator.generate(gender: :any)
        expect(%i[male female]).to include(result.metadata[:gender])
      end

      it 'handles :neutral gender by selecting randomly' do
        result = generator.generate(gender: :neutral)
        expect(%i[male female]).to include(result.metadata[:gender])
      end
    end

    context 'with culture parameter' do
      # Test a sample of cultures from each category
      %i[western nordic german french russian japanese arabic fantasy].each do |culture|
        it "generates names for #{culture} culture" do
          result = generator.generate(culture: culture)
          expect(result.metadata[:culture]).to eq(culture)
          expect(result.forename).not_to be_empty
        end
      end
    end

    context 'with pattern-based cultures' do
      described_class::PATTERN_CULTURES.each do |culture|
        it "generates pattern-based names for #{culture} culture" do
          result = generator.generate(culture: culture)
          expect(result.metadata[:culture]).to eq(culture)
          expect(result.forename).not_to be_empty
          expect(result.metadata[:mode]).to eq(:pattern_only)
        end
      end
    end

    context 'with setting/genre presets' do
      described_class::GENRE_DEFAULTS.each do |setting, expected_culture|
        it "uses #{expected_culture} culture for #{setting} setting" do
          result = generator.generate(setting: setting)
          expect(result.metadata[:culture]).to eq(expected_culture)
          expect(result.metadata[:setting]).to eq(setting)
        end
      end
    end

    context 'with forename_only option' do
      it 'generates only forename when forename_only is true' do
        result = generator.generate(forename_only: true)
        expect(result.forename).not_to be_empty
        expect(result.surname).to be_nil
        expect(result.full_name).to eq(result.forename)
      end
    end

    context 'with generation modes' do
      it 'uses pool_only mode when specified' do
        result = generator.generate(culture: :western, mode: :pool_only)
        expect(result.metadata[:mode]).to eq(:pool_only)
        expect(result.forename).not_to be_empty
      end

      it 'uses pattern_only mode when specified' do
        result = generator.generate(culture: :western, mode: :pattern_only)
        expect(result.metadata[:mode]).to eq(:pattern_only)
        expect(result.forename).not_to be_empty
      end

      it 'uses hybrid mode by default for real cultures' do
        result = generator.generate(culture: :western, mode: :auto)
        expect(result.metadata[:mode]).to eq(:hybrid)
      end

      it 'uses pattern_only mode by default for fantasy races' do
        result = generator.generate(culture: :elf, mode: :auto)
        expect(result.metadata[:mode]).to eq(:pattern_only)
      end
    end
  end

  describe '#generate_batch' do
    it 'generates multiple names' do
      results = generator.generate_batch(5)
      expect(results.length).to eq(5)
      expect(results).to all(be_a(NameGeneration::NameResult))
    end

    it 'passes options to each generation' do
      results = generator.generate_batch(3, gender: :female, culture: :nordic)
      results.each do |result|
        expect(result.metadata[:gender]).to eq(:female)
        expect(result.metadata[:culture]).to eq(:nordic)
      end
    end

    it 'generates requested count' do
      results = generator.generate_batch(10)
      expect(results.length).to eq(10)
    end
  end

  describe 'western names' do
    it 'generates typical western male names' do
      10.times do
        result = generator.generate(culture: :western, gender: :male)
        expect(result.forename).to match(/^[A-Z]/)
        expect(result.surname).not_to be_empty
      end
    end

    it 'generates typical western female names' do
      10.times do
        result = generator.generate(culture: :western, gender: :female)
        expect(result.forename).to match(/^[A-Z]/)
        expect(result.surname).not_to be_empty
      end
    end
  end

  describe 'nordic names' do
    it 'generates nordic names with appropriate patterns' do
      10.times do
        result = generator.generate(culture: :nordic)
        expect(result.forename).not_to be_empty
        expect(result.surname).not_to be_empty
      end
    end
  end

  describe 'fantasy names' do
    it 'generates elven names' do
      10.times do
        result = generator.generate(culture: :elf)
        expect(result.forename).not_to be_empty
        expect(result.surname).not_to be_empty
      end
    end

    it 'generates dwarven names' do
      10.times do
        result = generator.generate(culture: :dwarf)
        expect(result.forename).not_to be_empty
        expect(result.surname).not_to be_empty
      end
    end

    it 'generates orc names' do
      10.times do
        result = generator.generate(culture: :orc)
        expect(result.forename).not_to be_empty
        expect(result.surname).not_to be_empty
      end
    end
  end

  describe 'sci-fi names' do
    it 'generates alien names' do
      alien_results = []
      20.times do
        result = generator.generate(culture: :alien)
        alien_results << result
        expect(result.forename).not_to be_empty
        expect(result.surname).not_to be_empty
      end

      # Should have some variety
      unique_forenames = alien_results.map(&:forename).uniq
      expect(unique_forenames.length).to be >= 5
    end
  end

  describe 'all imported cultures' do
    # Test a broader range of imported cultures
    %i[german french italian spanish russian polish czech japanese korean chinese
       arabic hebrew turkish greek vietnamese thai indonesian].each do |culture|
      it "generates names for imported #{culture} culture" do
        result = generator.generate(culture: culture)
        expect(result.forename).not_to be_empty
        # Some cultures may not have surname files
        expect(result.full_name).not_to be_empty
      end
    end
  end

  describe 'fallback behavior' do
    it 'uses fallback names when data is unavailable' do
      # Create a generator and test with an unknown culture
      result = generator.generate(culture: :unknown_culture)
      # Should fall back to western
      expect(result.forename).not_to be_empty
    end
  end

  describe 'consistency and randomness' do
    it 'generates different names on successive calls' do
      names = 20.times.map { generator.generate.full_name }
      unique_names = names.uniq

      # Should have significant variety (at least 50% unique)
      expect(unique_names.length).to be >= 10
    end

    it 'produces valid names every time' do
      100.times do
        result = generator.generate
        expect(result.forename).to be_a(String)
        expect(result.forename.length).to be >= 2
        expect(result.surname).to be_a(String)
        expect(result.surname.length).to be >= 2
        expect(result.full_name).to include(' ')
      end
    end
  end
end
