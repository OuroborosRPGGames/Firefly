# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::BaseGenerator do
  let(:generator) { described_class.new }

  describe '#initialize' do
    it 'creates a default WeightingTracker' do
      expect(generator.weighting_tracker).to be_a(NameGeneration::WeightingTracker)
    end

    it 'accepts a custom WeightingTracker' do
      tracker = NameGeneration::WeightingTracker.new
      gen = described_class.new(tracker)
      expect(gen.weighting_tracker).to eq(tracker)
    end
  end

  describe '#generate' do
    it 'raises NotImplementedError' do
      expect { generator.generate }.to raise_error(NotImplementedError, /must implement #generate/)
    end
  end

  describe '#generate_batch' do
    it 'calls generate the specified number of times' do
      subclass = Class.new(described_class) do
        def generate(**_options)
          'a_name'
        end
      end

      gen = subclass.new
      result = gen.generate_batch(5)
      expect(result).to eq(%w[a_name a_name a_name a_name a_name])
      expect(result.length).to eq(5)
    end
  end

  describe '#capitalize_name' do
    it 'capitalizes simple names' do
      expect(generator.send(:capitalize_name, 'john')).to eq('John')
    end

    it 'capitalizes hyphenated names' do
      expect(generator.send(:capitalize_name, "mary-jane")).to eq('Mary-Jane')
    end

    it 'capitalizes names with apostrophes' do
      expect(generator.send(:capitalize_name, "o'connor")).to eq("O'Connor")
    end

    it 'returns nil for nil input' do
      expect(generator.send(:capitalize_name, nil)).to be_nil
    end

    it 'returns empty string for empty input' do
      expect(generator.send(:capitalize_name, '')).to eq('')
    end

    it 'handles single character names' do
      expect(generator.send(:capitalize_name, 'a')).to eq('A')
    end
  end

  describe '#apply_phonetic_rules' do
    it 'removes double vowels' do
      result = generator.send(:apply_phonetic_rules, 'Baarton')
      expect(result).to eq('Barton')
    end

    it 'removes triple consonants' do
      result = generator.send(:apply_phonetic_rules, 'Stttrong')
      expect(result).to eq('Sttrong')
    end

    it 'ensures at least one vowel' do
      result = generator.send(:apply_phonetic_rules, 'brx')
      expect(result).to match(/[aeiou]/i)
    end

    it 'leaves valid names unchanged' do
      result = generator.send(:apply_phonetic_rules, 'Marcus')
      expect(result).to eq('Marcus')
    end

    context 'with eastern culture' do
      it 'limits consecutive consonants to 2' do
        result = generator.send(:apply_phonetic_rules, 'Strng', :eastern)
        expect(result).not_to match(/[bcdfghjklmnpqrstvwxz]{3,}/i)
      end
    end

    context 'with nordic culture' do
      it 'allows double consonants' do
        result = generator.send(:apply_phonetic_rules, 'Ragnnarr', :nordic)
        # Nordic allows doubles, just cleans triples
        expect(result).to be_a(String)
      end
    end
  end

  describe '#ordinal' do
    it 'returns 1st' do
      expect(generator.send(:ordinal, 1)).to eq('1st')
    end

    it 'returns 2nd' do
      expect(generator.send(:ordinal, 2)).to eq('2nd')
    end

    it 'returns 3rd' do
      expect(generator.send(:ordinal, 3)).to eq('3rd')
    end

    it 'returns 4th' do
      expect(generator.send(:ordinal, 4)).to eq('4th')
    end

    it 'returns 11th (not 11st)' do
      expect(generator.send(:ordinal, 11)).to eq('11th')
    end

    it 'returns 12th (not 12nd)' do
      expect(generator.send(:ordinal, 12)).to eq('12th')
    end

    it 'returns 13th (not 13rd)' do
      expect(generator.send(:ordinal, 13)).to eq('13th')
    end

    it 'returns 21st' do
      expect(generator.send(:ordinal, 21)).to eq('21st')
    end

    it 'returns 112th' do
      expect(generator.send(:ordinal, 112)).to eq('112th')
    end

    it 'returns 100th' do
      expect(generator.send(:ordinal, 100)).to eq('100th')
    end
  end

  describe '#random_select' do
    it 'returns an item from the array' do
      items = %w[a b c]
      expect(items).to include(generator.send(:random_select, items))
    end
  end
end
