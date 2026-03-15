# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NameGeneration do
  describe 'NameGeneration::NameResult' do
    describe 'initialization' do
      it 'accepts keyword arguments' do
        result = NameGeneration::NameResult.new(
          forename: 'John',
          surname: 'Smith',
          full_name: 'John Smith',
          metadata: { origin: 'english' }
        )
        expect(result.forename).to eq('John')
        expect(result.surname).to eq('Smith')
        expect(result.full_name).to eq('John Smith')
        expect(result.metadata).to eq({ origin: 'english' })
      end

      it 'allows nil values' do
        result = NameGeneration::NameResult.new(forename: 'Alice')
        expect(result.forename).to eq('Alice')
        expect(result.surname).to be_nil
        expect(result.full_name).to be_nil
        expect(result.metadata).to be_nil
      end
    end

    describe '#to_s' do
      it 'returns full_name when present' do
        result = NameGeneration::NameResult.new(forename: 'John', full_name: 'John Smith Jr.')
        expect(result.to_s).to eq('John Smith Jr.')
      end

      it 'returns forename when full_name is nil' do
        result = NameGeneration::NameResult.new(forename: 'Alice', full_name: nil)
        expect(result.to_s).to eq('Alice')
      end

      it 'returns nil when both are nil' do
        result = NameGeneration::NameResult.new
        expect(result.to_s).to be_nil
      end
    end

    describe '#to_h' do
      it 'returns hash with basic fields' do
        result = NameGeneration::NameResult.new(
          forename: 'John',
          surname: 'Smith',
          full_name: 'John Smith'
        )
        expect(result.to_h).to include(
          forename: 'John',
          surname: 'Smith',
          full_name: 'John Smith'
        )
      end

      it 'merges metadata into hash' do
        result = NameGeneration::NameResult.new(
          forename: 'John',
          surname: 'Smith',
          full_name: 'John Smith',
          metadata: { origin: 'english', culture: 'british' }
        )
        hash = result.to_h
        expect(hash[:origin]).to eq('english')
        expect(hash[:culture]).to eq('british')
      end

      it 'handles nil metadata' do
        result = NameGeneration::NameResult.new(
          forename: 'John',
          surname: 'Smith',
          full_name: 'John Smith',
          metadata: nil
        )
        expect(result.to_h).to eq({
                                    forename: 'John',
                                    surname: 'Smith',
                                    full_name: 'John Smith'
                                  })
      end
    end
  end

  describe 'NameGeneration::CityResult' do
    describe 'initialization' do
      it 'accepts keyword arguments' do
        result = NameGeneration::CityResult.new(
          name: 'Ravenmoor',
          pattern: 'prefix_suffix',
          setting: 'fantasy',
          metadata: { syllables: 3 }
        )
        expect(result.name).to eq('Ravenmoor')
        expect(result.pattern).to eq('prefix_suffix')
        expect(result.setting).to eq('fantasy')
        expect(result.metadata).to eq({ syllables: 3 })
      end
    end

    describe '#to_s' do
      it 'returns the city name' do
        result = NameGeneration::CityResult.new(name: 'Shadowfell')
        expect(result.to_s).to eq('Shadowfell')
      end
    end

    describe '#to_h' do
      it 'returns hash with basic fields' do
        result = NameGeneration::CityResult.new(
          name: 'Ravenmoor',
          pattern: 'prefix_suffix',
          setting: 'fantasy'
        )
        expect(result.to_h).to include(
          name: 'Ravenmoor',
          pattern: 'prefix_suffix',
          setting: 'fantasy'
        )
      end

      it 'merges metadata into hash' do
        result = NameGeneration::CityResult.new(
          name: 'Ravenmoor',
          pattern: 'prefix_suffix',
          setting: 'fantasy',
          metadata: { region: 'north', population: 5000 }
        )
        hash = result.to_h
        expect(hash[:region]).to eq('north')
        expect(hash[:population]).to eq(5000)
      end

      it 'handles nil metadata' do
        result = NameGeneration::CityResult.new(name: 'TestCity', metadata: nil)
        expect { result.to_h }.not_to raise_error
      end
    end
  end

  describe 'NameGeneration::StreetResult' do
    describe 'initialization' do
      it 'accepts keyword arguments' do
        result = NameGeneration::StreetResult.new(
          name: 'Maple Street',
          style: 'tree_street',
          setting: 'modern',
          metadata: { direction: 'north_south' }
        )
        expect(result.name).to eq('Maple Street')
        expect(result.style).to eq('tree_street')
        expect(result.setting).to eq('modern')
        expect(result.metadata).to eq({ direction: 'north_south' })
      end
    end

    describe '#to_s' do
      it 'returns the street name' do
        result = NameGeneration::StreetResult.new(name: 'Oak Avenue')
        expect(result.to_s).to eq('Oak Avenue')
      end
    end

    describe '#to_h' do
      it 'returns hash with basic fields' do
        result = NameGeneration::StreetResult.new(
          name: 'Elm Drive',
          style: 'tree_drive',
          setting: 'suburban'
        )
        expect(result.to_h).to include(
          name: 'Elm Drive',
          style: 'tree_drive',
          setting: 'suburban'
        )
      end

      it 'merges metadata into hash' do
        result = NameGeneration::StreetResult.new(
          name: 'Main Street',
          style: 'generic',
          setting: 'urban',
          metadata: { commercial: true }
        )
        expect(result.to_h[:commercial]).to be true
      end

      it 'handles nil metadata' do
        result = NameGeneration::StreetResult.new(name: 'Test St', metadata: nil)
        expect { result.to_h }.not_to raise_error
      end
    end
  end

  describe 'NameGeneration::ShopResult' do
    describe 'initialization' do
      it 'accepts keyword arguments' do
        result = NameGeneration::ShopResult.new(
          name: "Bob's Bakery",
          shop_type: 'bakery',
          pattern_used: 'possessive_type',
          setting: 'modern',
          metadata: { owner_name: 'Bob' }
        )
        expect(result.name).to eq("Bob's Bakery")
        expect(result.shop_type).to eq('bakery')
        expect(result.pattern_used).to eq('possessive_type')
        expect(result.setting).to eq('modern')
        expect(result.metadata).to eq({ owner_name: 'Bob' })
      end
    end

    describe '#to_s' do
      it 'returns the shop name' do
        result = NameGeneration::ShopResult.new(name: 'The Golden Anvil')
        expect(result.to_s).to eq('The Golden Anvil')
      end
    end

    describe '#to_h' do
      it 'returns hash with all fields' do
        result = NameGeneration::ShopResult.new(
          name: 'The Iron Forge',
          shop_type: 'blacksmith',
          pattern_used: 'the_adjective_noun',
          setting: 'fantasy'
        )
        expect(result.to_h).to include(
          name: 'The Iron Forge',
          shop_type: 'blacksmith',
          pattern_used: 'the_adjective_noun',
          setting: 'fantasy'
        )
      end

      it 'merges metadata into hash' do
        result = NameGeneration::ShopResult.new(
          name: 'Ye Olde Pub',
          shop_type: 'tavern',
          pattern_used: 'ye_olde',
          setting: 'medieval',
          metadata: { serves_food: true, has_rooms: true }
        )
        hash = result.to_h
        expect(hash[:serves_food]).to be true
        expect(hash[:has_rooms]).to be true
      end

      it 'handles nil metadata' do
        result = NameGeneration::ShopResult.new(name: 'Test Shop', metadata: nil)
        expect { result.to_h }.not_to raise_error
      end
    end
  end

  describe 'common struct behavior' do
    it 'all result types support nil-safe to_h' do
      [
        NameGeneration::NameResult.new,
        NameGeneration::CityResult.new,
        NameGeneration::StreetResult.new,
        NameGeneration::ShopResult.new
      ].each do |result|
        expect { result.to_h }.not_to raise_error
      end
    end

    it 'all result types support to_s' do
      [
        NameGeneration::NameResult.new(forename: 'Test'),
        NameGeneration::CityResult.new(name: 'Test'),
        NameGeneration::StreetResult.new(name: 'Test'),
        NameGeneration::ShopResult.new(name: 'Test')
      ].each do |result|
        expect(result.to_s).to eq('Test')
      end
    end

    it 'all result types are keyword-init structs' do
      # Verify keyword initialization works for all
      expect { NameGeneration::NameResult.new(forename: 'A', surname: 'B') }.not_to raise_error
      expect { NameGeneration::CityResult.new(name: 'A', pattern: 'B') }.not_to raise_error
      expect { NameGeneration::StreetResult.new(name: 'A', style: 'B') }.not_to raise_error
      expect { NameGeneration::ShopResult.new(name: 'A', shop_type: 'B') }.not_to raise_error
    end
  end

  describe 'usage in generators' do
    it 'NameResult can be used like a hash when needed' do
      result = NameGeneration::NameResult.new(
        forename: 'John',
        surname: 'Doe',
        full_name: 'John Doe'
      )

      # Common pattern: pass result to methods expecting a hash
      hash = result.to_h
      expect(hash[:forename]).to eq('John')
      expect(hash[:surname]).to eq('Doe')
    end

    it 'results can be compared by values' do
      result1 = NameGeneration::NameResult.new(forename: 'John', surname: 'Doe', full_name: 'John Doe')
      result2 = NameGeneration::NameResult.new(forename: 'John', surname: 'Doe', full_name: 'John Doe')

      expect(result1).to eq(result2)
    end

    it 'results preserve metadata across operations' do
      original_metadata = { source: 'test', generated_at: Time.now.to_i }
      result = NameGeneration::CityResult.new(
        name: 'TestCity',
        pattern: 'test',
        setting: 'test',
        metadata: original_metadata
      )

      hash = result.to_h
      expect(hash[:source]).to eq('test')
      expect(hash[:generated_at]).to eq(original_metadata[:generated_at])
    end
  end
end
