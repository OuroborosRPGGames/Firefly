# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::PatternGenerator do
  describe '.compile' do
    it 'compiles a simple pattern' do
      generator = described_class.compile('abc')
      expect(generator).to be_a(described_class::Generator)
    end

    it 'generates literal strings' do
      generator = described_class.compile('hello')
      expect(generator.generate).to eq('hello')
    end

    it 'handles symbol substitution for vowels' do
      generator = described_class.compile('v')
      100.times do
        result = generator.generate
        expect(%w[a e i o u y]).to include(result)
      end
    end

    it 'handles symbol substitution for consonants' do
      generator = described_class.compile('c')
      100.times do
        result = generator.generate
        expect(described_class::SYMBOLS['c']).to include(result)
      end
    end

    it 'handles symbol substitution for syllables' do
      generator = described_class.compile('s')
      100.times do
        result = generator.generate
        expect(described_class::SYMBOLS['s']).to include(result)
      end
    end
  end

  describe 'capitalization' do
    it 'capitalizes with ! modifier' do
      generator = described_class.compile('!v')
      100.times do
        result = generator.generate
        expect(result).to match(/^[AEIOUY]$/)
      end
    end

    it 'capitalizes literal text' do
      generator = described_class.compile('!(hello)')
      expect(generator.generate).to eq('Hello')
    end
  end

  describe 'reversal' do
    it 'reverses with ~ modifier' do
      generator = described_class.compile('~(hello)')
      expect(generator.generate).to eq('olleh')
    end
  end

  describe 'literal groups' do
    it 'handles literal groups with ()' do
      generator = described_class.compile('(hello)')
      expect(generator.generate).to eq('hello')
    end

    it 'mixes literals and symbols' do
      generator = described_class.compile('(Dr.)s')
      100.times do
        result = generator.generate
        expect(result).to start_with('Dr.')
        expect(result.length).to be > 3
      end
    end
  end

  describe 'symbol groups' do
    it 'handles symbol groups with <>' do
      generator = described_class.compile('<sv>')
      100.times do
        result = generator.generate
        # Should be syllable + vowel
        expect(result.length).to be >= 2
      end
    end
  end

  describe 'choices' do
    it 'handles choices with |' do
      generator = described_class.compile('(a|b|c)')
      results = 100.times.map { generator.generate }
      expect(results.uniq.sort).to eq(%w[a b c])
    end

    it 'handles empty choices' do
      generator = described_class.compile('(a|)')
      results = 100.times.map { generator.generate }
      expect(results).to include('a')
      expect(results).to include('')
    end
  end

  describe 'complex patterns' do
    it 'generates elven-style names' do
      generator = described_class.compile("!sVsV")
      100.times do
        result = generator.generate
        expect(result).to match(/^[A-Z]/)
        expect(result.length).to be >= 4
      end
    end

    it 'generates dwarven-style names' do
      generator = described_class.compile('!BVrC')
      100.times do
        result = generator.generate
        expect(result).to match(/^[A-Z]/)
        expect(result).to include('r')
      end
    end

    it 'generates names with apostrophes' do
      generator = described_class.compile("!sV'sV")
      100.times do
        result = generator.generate
        expect(result).to match(/^[A-Z]/)
        expect(result).to include("'")
      end
    end
  end

  describe '.generate' do
    it 'is a shortcut for compile and generate' do
      result = described_class.generate('!BVs')
      expect(result).to match(/^[A-Z]/)
    end
  end

  describe '.generate_for_race' do
    described_class::PATTERNS.each_key do |race|
      context "for #{race}" do
        it 'generates valid names' do
          100.times do
            result = described_class.generate_for_race(race)
            expect(result).to be_a(String)
            expect(result).not_to be_empty
            expect(result).to match(/^[A-Z]/)
          end
        end
      end
    end

    it 'falls back to human_fantasy for unknown races' do
      result = described_class.generate_for_race(:unknown)
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end
  end

  describe 'error handling' do
    it 'raises on unbalanced brackets' do
      expect { described_class.compile('(hello') }.to raise_error(/Missing closing bracket/)
      expect { described_class.compile('hello)') }.to raise_error(/Unbalanced brackets/)
      expect { described_class.compile('<hello') }.to raise_error(/Missing closing bracket/)
      expect { described_class.compile('hello>') }.to raise_error(/Unbalanced brackets/)
    end

    it 'raises on mismatched brackets' do
      expect { described_class.compile('(hello>') }.to raise_error(/Unexpected ">"/)
      expect { described_class.compile('<hello)') }.to raise_error(/Unexpected "\)"/)
    end
  end

  describe 'reproducibility' do
    it 'generates different names on successive calls' do
      generator = described_class.compile('!BVsVs')
      names = 50.times.map { generator.generate }
      expect(names.uniq.length).to be > 10
    end
  end
end
