# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SeedTermService do
  describe 'constants' do
    it 'defines AVAILABLE_TABLES' do
      expect(described_class::AVAILABLE_TABLES).to include(
        :physical_adjectives, :materials, :character_descriptors
      )
    end

    it 'includes all expected adjective tables' do
      %i[physical_adjectives size_adjectives age_adjectives quality_adjectives
         spatial_adjectives atmosphere_adjectives lighting_adjectives].each do |table|
        expect(described_class::AVAILABLE_TABLES).to include(table)
      end
    end

    it 'includes character-related tables' do
      %i[character_descriptors character_personality character_motivations character_identity].each do |table|
        expect(described_class::AVAILABLE_TABLES).to include(table)
      end
    end

    it 'defines GENERATION_CATEGORIES' do
      expect(described_class::GENERATION_CATEGORIES.keys).to include(
        :item, :npc, :room, :place, :city, :dungeon, :creature, :shop, :wilderness, :lore
      )
    end

    it 'maps item to physical descriptors' do
      expect(described_class::GENERATION_CATEGORIES[:item]).to include(
        :physical_adjectives, :materials, :quality_adjectives
      )
    end

    it 'maps npc to character descriptors' do
      expect(described_class::GENERATION_CATEGORIES[:npc]).to include(
        :character_descriptors, :character_personality
      )
    end

    it 'maps room to spatial and atmospheric descriptors' do
      expect(described_class::GENERATION_CATEGORIES[:room]).to include(
        :spatial_adjectives, :atmosphere_adjectives
      )
    end
  end

  describe '.for_generation' do
    before do
      allow(described_class).to receive(:sample).and_return(['test_term'])
    end

    it 'returns requested number of terms' do
      allow(described_class).to receive(:sample).and_return(
        %w[term1 term2 term3 term4 term5 term6 term7 term8]
      )

      result = described_class.for_generation(:item, count: 5)

      expect(result.length).to eq(5)
    end

    it 'samples from appropriate categories for item' do
      expect(described_class).to receive(:sample).with(:physical_adjectives, count: 2).and_return(['rusty'])
      expect(described_class).to receive(:sample).with(:materials, count: 2).and_return(['brass'])
      expect(described_class).to receive(:sample).with(:quality_adjectives, count: 2).and_return(['fine'])
      expect(described_class).to receive(:sample).with(:age_adjectives, count: 2).and_return(['ancient'])

      described_class.for_generation(:item, count: 5)
    end

    it 'samples from appropriate categories for npc' do
      expect(described_class).to receive(:sample).with(:character_descriptors, count: 2).and_return(['tall'])
      expect(described_class).to receive(:sample).with(:character_personality, count: 2).and_return(['cheerful'])
      expect(described_class).to receive(:sample).with(:character_motivations, count: 2).and_return(['greed'])
      expect(described_class).to receive(:sample).with(:character_identity, count: 2).and_return(['merchant'])

      described_class.for_generation(:npc, count: 5)
    end

    it 'uses character_descriptors as default for unknown task type' do
      expect(described_class).to receive(:sample).with(:character_descriptors, count: 5).and_return(['default'])

      described_class.for_generation(:unknown_type, count: 5)
    end

    it 'returns unique terms' do
      allow(described_class).to receive(:sample).and_return(%w[repeat repeat unique])

      result = described_class.for_generation(:item, count: 2)

      expect(result).to eq(result.uniq)
    end

    it 'accepts string task type' do
      expect(described_class).to receive(:sample).at_least(:once).and_return(['term'])

      described_class.for_generation('item', count: 3)
    end

    it 'defaults to count of 5' do
      allow(described_class).to receive(:sample).and_return(%w[a b c d e f g h])

      result = described_class.for_generation(:item)

      expect(result.length).to eq(5)
    end
  end

  describe '.sample' do
    let(:entries) { %w[weathered rusty gleaming ancient tarnished] }

    before do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).with(:seed_term_entries).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:select_map).with(:entry).and_return(entries)
    end

    it 'queries the correct table' do
      dataset = double('Dataset')
      expect(DB).to receive(:[]).with(:seed_term_entries).and_return(dataset)
      expect(dataset).to receive(:where).with(table_name: 'physical_adjectives').and_return(dataset)
      allow(dataset).to receive(:select_map).and_return(entries)

      described_class.sample(:physical_adjectives)
    end

    it 'returns requested count of entries' do
      result = described_class.sample(:physical_adjectives, count: 3)

      expect(result.length).to eq(3)
    end

    it 'returns single entry by default' do
      result = described_class.sample(:physical_adjectives)

      expect(result.length).to eq(1)
    end

    it 'returns empty array when no entries exist' do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:select_map).and_return([])

      result = described_class.sample(:empty_table, count: 5)

      expect(result).to eq([])
    end

    it 'returns all entries if count exceeds available' do
      result = described_class.sample(:physical_adjectives, count: 100)

      expect(result.length).to eq(entries.length)
    end

    it 'converts symbol table_name to string' do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).and_return(dataset)
      expect(dataset).to receive(:where).with(table_name: 'test_table').and_return(dataset)
      allow(dataset).to receive(:select_map).and_return([])

      described_class.sample(:test_table)
    end
  end

  describe '.categorized' do
    before do
      allow(described_class).to receive(:sample).and_return(%w[term1 term2])
    end

    it 'returns hash with category keys' do
      result = described_class.categorized(
        categories: [:physical_adjectives, :materials],
        count_per_category: 2
      )

      expect(result.keys).to eq([:physical_adjectives, :materials])
    end

    it 'samples from each category' do
      expect(described_class).to receive(:sample).with(:physical_adjectives, count: 2)
      expect(described_class).to receive(:sample).with(:materials, count: 2)

      described_class.categorized(
        categories: [:physical_adjectives, :materials],
        count_per_category: 2
      )
    end

    it 'defaults to 2 samples per category' do
      expect(described_class).to receive(:sample).with(:physical_adjectives, count: 2).and_return(['x'])

      described_class.categorized(categories: [:physical_adjectives])
    end
  end

  describe '.combined_descriptors' do
    before do
      allow(described_class).to receive(:sample).with(:physical_adjectives, count: 2).and_return(%w[rusty gleaming])
      allow(described_class).to receive(:sample).with(:object_types, count: 2).and_return(%w[sword chalice])
    end

    it 'combines adjectives with nouns' do
      result = described_class.combined_descriptors(count: 2)

      expect(result).to eq(['rusty sword', 'gleaming chalice'])
    end

    it 'downcases the result' do
      allow(described_class).to receive(:sample).with(:physical_adjectives, count: 1).and_return(['RUSTY'])
      allow(described_class).to receive(:sample).with(:object_types, count: 1).and_return(['SWORD'])

      result = described_class.combined_descriptors(count: 1)

      expect(result.first).to eq('rusty sword')
    end
  end

  describe '.adventure_tones' do
    before do
      allow(described_class).to receive(:sample).and_return(%w[heroic mysterious])
    end

    it 'samples from adventure_tone table' do
      expect(described_class).to receive(:sample).with(:adventure_tone, count: 2)

      described_class.adventure_tones(count: 2)
    end

    it 'defaults to 2 tones' do
      expect(described_class).to receive(:sample).with(:adventure_tone, count: 2)

      described_class.adventure_tones
    end
  end

  describe '.available_tables' do
    it 'returns AVAILABLE_TABLES constant' do
      expect(described_class.available_tables).to eq(described_class::AVAILABLE_TABLES)
    end
  end

  describe '.all_entries' do
    before do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).with(:seed_term_entries).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      allow(dataset).to receive(:order).and_return(dataset)
      allow(dataset).to receive(:select_map).and_return(%w[entry1 entry2 entry3])
    end

    it 'queries entries ordered by position' do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).and_return(dataset)
      allow(dataset).to receive(:where).and_return(dataset)
      expect(dataset).to receive(:order).with(:position).and_return(dataset)
      allow(dataset).to receive(:select_map).and_return([])

      described_class.all_entries(:test_table)
    end

    it 'returns all entries for table' do
      result = described_class.all_entries(:test_table)

      expect(result).to eq(%w[entry1 entry2 entry3])
    end
  end

  describe '.table_info' do
    before do
      allow(described_class).to receive(:all_entries).and_return(%w[a b c d e f])
    end

    it 'returns info for each available table' do
      result = described_class.table_info

      expect(result.length).to eq(described_class::AVAILABLE_TABLES.length)
    end

    it 'includes name, count, and sample for each table' do
      result = described_class.table_info.first

      expect(result).to include(:name, :count, :sample)
    end

    it 'limits sample to first 5 entries' do
      allow(described_class).to receive(:all_entries).and_return(%w[a b c d e f g h i j])

      result = described_class.table_info.first

      expect(result[:sample].length).to eq(5)
    end
  end

  describe '.seeded?' do
    it 'returns true when entries exist' do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).with(:seed_term_entries).and_return(dataset)
      allow(dataset).to receive(:any?).and_return(true)

      expect(described_class.seeded?).to be true
    end

    it 'returns false when no entries exist' do
      dataset = double('Dataset')
      allow(DB).to receive(:[]).with(:seed_term_entries).and_return(dataset)
      allow(dataset).to receive(:any?).and_return(false)

      expect(described_class.seeded?).to be false
    end

    it 'returns false on database error' do
      allow(DB).to receive(:[]).and_raise(Sequel::DatabaseError)

      expect(described_class.seeded?).to be false
    end
  end

  describe 'backward compatibility aliases' do
    before do
      allow(described_class).to receive(:sample).and_return(['term'])
    end

    describe '.flat_seed_terms' do
      it 'calls for_generation with count param' do
        expect(described_class).to receive(:for_generation).with(:item, count: 4)

        described_class.flat_seed_terms(:item, total: 4)
      end
    end

    describe '.seed_terms_for' do
      it 'calls categorized with appropriate categories' do
        expect(described_class).to receive(:categorized).with(
          categories: described_class::GENERATION_CATEGORIES[:item],
          count_per_category: 2
        )

        described_class.seed_terms_for(:item, count_per_category: 2)
      end

      it 'uses character_descriptors for unknown type' do
        expect(described_class).to receive(:categorized).with(
          categories: [:character_descriptors],
          count_per_category: 2
        )

        described_class.seed_terms_for(:unknown, count_per_category: 2)
      end
    end

    describe '.seed_terms' do
      it 'calls categorized with provided categories' do
        expect(described_class).to receive(:categorized).with(
          categories: [:physical_adjectives, :materials],
          count_per_category: 3
        )

        described_class.seed_terms(categories: [:physical_adjectives, :materials], count_per_category: 3)
      end
    end
  end
end
