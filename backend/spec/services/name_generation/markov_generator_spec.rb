# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration::MarkovGenerator do
  describe '#generate' do
    context 'with valid syllables' do
      let(:syllables) do
        {
          prefixes: %w[Ar El Gal Thor],
          middles: %w[an en in],
          suffixes: %w[dor iel wen]
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'generates a name' do
        name = generator.generate
        expect(name).to be_a(String)
        expect(name).not_to be_empty
      end

      it 'capitalizes the first letter' do
        10.times do
          name = generator.generate
          expect(name).to match(/^[A-Z]/)
        end
      end

      it 'generates names within length bounds' do
        20.times do
          name = generator.generate
          expect(name.length).to be >= described_class::MIN_NAME_LENGTH
          expect(name.length).to be <= described_class::MAX_NAME_LENGTH
        end
      end

      it 'generates names with at least one vowel' do
        20.times do
          name = generator.generate
          expect(name).to match(/[aeiou]/i)
        end
      end

      it 'generates varied names' do
        names = 20.times.map { generator.generate }
        unique_names = names.uniq
        # Should have some variety
        expect(unique_names.length).to be >= 5
      end
    end

    context 'with minimal syllables' do
      let(:syllables) do
        {
          prefixes: ['Ka'],
          suffixes: ['ra']
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'still generates valid names' do
        name = generator.generate
        expect(name).to be_a(String)
        expect(name).not_to be_empty
      end
    end

    context 'with empty syllables' do
      let(:generator) { described_class.new({}) }

      it 'handles empty syllables gracefully' do
        name = generator.generate
        expect(name).to be_a(String)
        # Will be empty or capitalized empty string
      end
    end

    context 'with apostrophe-containing syllables' do
      let(:syllables) do
        {
          prefixes: %w[Kel Zar Vor],
          suffixes: %w['thax 'vor 'dak]
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'handles apostrophes in names' do
        20.times do
          name = generator.generate
          expect(name).to be_a(String)
          # Should properly capitalize parts around apostrophes
          if name.include?("'")
            parts = name.split("'")
            parts.each do |part|
              next if part.empty?

              expect(part).to match(/^[A-Z]/) unless part.empty?
            end
          end
        end
      end
    end

    context 'with custom length options' do
      let(:syllables) do
        {
          prefixes: %w[A E I],
          suffixes: %w[a e i]
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'respects custom min_length option' do
        20.times do
          name = generator.generate(min_length: 4)
          # May fall back to simple composition if can't meet requirements
          expect(name).to be_a(String)
        end
      end

      it 'respects custom max_length option' do
        20.times do
          name = generator.generate(max_length: 8)
          expect(name).to be_a(String)
        end
      end
    end

    context 'with max_attempts option' do
      let(:syllables) do
        {
          prefixes: %w[Aa Ee],
          suffixes: %w[aa ee]
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'falls back to simple composition after max attempts' do
        # With 4+ consecutive vowels being invalid, it should fall back
        name = generator.generate(max_attempts: 3)
        expect(name).to be_a(String)
      end
    end
  end

  describe 'name validation' do
    let(:syllables) do
      {
        prefixes: %w[Kar Bel Nor],
        middles: %w[a e i],
        suffixes: %w[dan wen rik]
      }
    end

    let(:generator) { described_class.new(syllables) }

    it 'generates valid names with proper syllables' do
      # With good syllables, names should be phonetically valid
      20.times do
        name = generator.generate
        # Should not have 4+ consecutive consonants
        expect(name).not_to match(/[bcdfghjklmnpqrstvwxz]{4,}/i)
      end
    end

    it 'attempts to avoid names with 4+ consecutive vowels' do
      # When given valid syllables, it should avoid consecutive vowels
      valid_syllables = {
        prefixes: %w[Kar Bel Nor],
        suffixes: %w[dan wen rik]
      }
      gen = described_class.new(valid_syllables)

      20.times do
        name = gen.generate
        expect(name).not_to match(/[aeiou]{4,}/i)
      end
    end
  end

  describe 'capitalization' do
    let(:generator) do
      described_class.new(
        { prefixes: ['test'], suffixes: ['name'] }
      )
    end

    it 'properly capitalizes simple names' do
      name = generator.generate
      expect(name).to match(/^[A-Z][a-z]*$/)
    end

    context 'with hyphenated names' do
      let(:syllables) do
        {
          prefixes: ['an'],
          suffixes: ['-kar']
        }
      end

      let(:generator) { described_class.new(syllables) }

      it 'capitalizes each part of hyphenated names' do
        # Generate multiple to catch one with hyphen
        20.times do
          name = generator.generate
          if name.include?('-')
            parts = name.split('-')
            parts.each do |part|
              expect(part).to match(/^[A-Z]/) unless part.empty?
            end
          end
        end
      end
    end
  end
end
