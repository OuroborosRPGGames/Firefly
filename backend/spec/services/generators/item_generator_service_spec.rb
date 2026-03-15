# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::ItemGeneratorService do
  let(:seed_terms) { %w[ornate elegant mysterious] }

  before do
    allow(SeedTermService).to receive(:for_generation).and_return(seed_terms)
    allow(GamePrompts).to receive(:get).and_return('Generated prompt')
  end

  describe '.generate' do
    before do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: {
          'name' => 'An Ornate Silver Dagger with bone handle',
          'description' => 'A beautifully crafted silver dagger with ornate engravings.'
        }
      })
    end

    it 'generates name and description in a single call' do
      result = described_class.generate(
        category: :weapon,
        setting: :fantasy
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('ornate silver dagger with bone handle')
      expect(result[:description]).to include('silver dagger')
    end

    it 'includes seed terms in results' do
      result = described_class.generate(category: :jewelry)

      expect(result[:seed_terms]).to eq(seed_terms)
    end

    it 'uses provided seed terms' do
      custom_terms = %w[ancient rusted]
      result = described_class.generate(
        category: :weapon,
        seed_terms: custom_terms
      )

      expect(result[:seed_terms]).to eq(custom_terms)
    end

    context 'with subcategory' do
      it 'uses subcategory in generation' do
        result = described_class.generate(
          category: :clothing,
          subcategory: 'dress'
        )

        expect(result[:success]).to be true
      end
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false,
          error: 'Service unavailable'
        })
      end

      it 'returns error' do
        result = described_class.generate(category: :weapon)

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Service unavailable')
      end
    end

    context 'with generate_image: true' do
      before do
        allow(WorldBuilderImageService).to receive(:generate).and_return({
          success: true,
          local_url: '/images/item.png'
        })
      end

      it 'generates image' do
        result = described_class.generate(
          category: :weapon,
          generate_image: true
        )

        expect(result[:image_url]).to eq('/images/item.png')
      end
    end

    context 'when profile returns no description' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false, error: 'Failed'
        })
      end

      it 'does not attempt image generation' do
        expect(WorldBuilderImageService).not_to receive(:generate)

        described_class.generate(category: :weapon, generate_image: true)
      end
    end
  end

  describe '.generate_item_profile' do
    before do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: {
          'name' => 'A Polished Silver Ring with sapphire',
          'description' => 'Gleaming silver band set with a deep blue sapphire.'
        }
      })
    end

    it 'returns name and description from a single call' do
      result = described_class.generate_item_profile(
        category: :jewelry,
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('polished silver ring with sapphire')
      expect(result[:description]).to include('sapphire')
    end

    it 'cleans up name (lowercase, no articles, no quotes)' do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: { 'name' => '"The Ancient Bronze Shield"', 'description' => 'Old.' }
      })

      result = described_class.generate_item_profile(category: :weapon)

      expect(result[:name]).to eq('ancient bronze shield')
    end

    it 'uses the item_profile prompt' do
      expect(GamePrompts).to receive(:get).with('generators.item_profile', anything)

      described_class.generate_item_profile(category: :jewelry)
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false, error: 'LLM error'
        })
      end

      it 'returns error' do
        result = described_class.generate_item_profile(category: :weapon)

        expect(result[:success]).to be false
        expect(result[:error]).to include('LLM error')
      end
    end
  end

  describe '.generate_name' do
    before do
      allow(GenerationPipelineService).to receive(:generate_simple).and_return({
        success: true,
        content: '"An Ornate Silver Ring"'
      })
    end

    it 'generates item name' do
      result = described_class.generate_name(
        category: :jewelry,
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('ornate silver ring')
    end

    it 'removes quotes from name' do
      result = described_class.generate_name(category: :weapon)

      expect(result[:name]).not_to include('"')
    end

    it 'removes articles from name' do
      result = described_class.generate_name(category: :clothing)

      expect(result[:name]).not_to start_with('an ')
    end

    it 'lowercases the name' do
      result = described_class.generate_name(category: :jewelry)

      expect(result[:name]).to eq(result[:name].downcase)
    end

    context 'with subcategory' do
      it 'uses subcategory as type' do
        expect(GamePrompts).to receive(:get).with(
          'generators.item_name',
          hash_including(type_str: 'ring')
        )

        described_class.generate_name(
          category: :jewelry,
          subcategory: 'ring'
        )
      end
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: false,
          error: 'LLM error'
        })
      end

      it 'returns error' do
        result = described_class.generate_name(category: :weapon)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('LLM error')
      end
    end
  end

  describe '.generate_description' do
    let(:pattern) do
      double('Pattern',
             id: 1,
             name: 'Silver Ring',
             description: 'Elegant silver ring',
             subcategory: 'ring',
             clothing?: false,
             jewelry?: true,
             weapon?: false,
             consumable?: false)
    end

    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'A polished silver ring with intricate engravings.'
      })
    end

    it 'generates description for pattern' do
      result = described_class.generate_description(
        pattern: pattern,
        setting: :fantasy
      )

      expect(result[:success]).to be true
      expect(result[:content]).to include('silver ring')
    end

    it 'uses provided seed terms' do
      custom_terms = %w[ancient magical]
      result = described_class.generate_description(
        pattern: pattern,
        seed_terms: custom_terms
      )

      expect(result[:success]).to be true
    end

    context 'with clothing pattern' do
      let(:clothing_pattern) do
        double('Pattern',
               id: 2,
               name: 'Silk Dress',
               description: nil,
               subcategory: 'dress',
               clothing?: true,
               jewelry?: false,
               weapon?: false,
               consumable?: false)
      end

      it 'categorizes as clothing' do
        result = described_class.generate_description(pattern: clothing_pattern)

        expect(result[:success]).to be true
      end
    end

    context 'with weapon pattern' do
      let(:weapon_pattern) do
        double('Pattern',
               id: 3,
               name: 'Iron Sword',
               description: nil,
               subcategory: 'sword',
               clothing?: false,
               jewelry?: false,
               weapon?: true,
               consumable?: false)
      end

      it 'categorizes as weapon' do
        result = described_class.generate_description(pattern: weapon_pattern)

        expect(result[:success]).to be true
      end
    end
  end

  describe '.generate_image' do
    before do
      allow(WorldBuilderImageService).to receive(:generate).and_return({
        success: true,
        url: 'https://example.com/item.png',
        local_url: '/images/item.png'
      })
    end

    it 'generates image via WorldBuilderImageService' do
      result = described_class.generate_image(
        description: 'A silver ring',
        category: :jewelry
      )

      expect(result[:local_url]).to eq('/images/item.png')
    end

    it 'uses correct style for category' do
      expect(WorldBuilderImageService).to receive(:generate).with(
        hash_including(type: :item_on_black)
      )

      described_class.generate_image(
        description: 'A sword',
        category: :weapon
      )
    end

    it 'uses item_on_model for clothing' do
      expect(WorldBuilderImageService).to receive(:generate).with(
        hash_including(type: :item_on_model)
      )

      described_class.generate_image(
        description: 'A dress',
        category: :clothing
      )
    end

    it 'allows style override' do
      expect(WorldBuilderImageService).to receive(:generate).with(
        hash_including(type: :custom_style)
      )

      described_class.generate_image(
        description: 'Test',
        category: :misc,
        options: { style: :custom_style }
      )
    end
  end

  describe '.generate_descriptions_batch' do
    let(:patterns) do
      [
        double('Pattern', id: 1, name: 'Ring', description: nil, subcategory: 'ring',
               clothing?: false, jewelry?: true, weapon?: false, consumable?: false),
        double('Pattern', id: 2, name: 'Sword', description: nil, subcategory: 'sword',
               clothing?: false, jewelry?: false, weapon?: true, consumable?: false)
      ]
    end

    before do
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Batch description'
      })
    end

    it 'generates descriptions for multiple patterns' do
      results = described_class.generate_descriptions_batch(
        patterns: patterns,
        setting: :fantasy
      )

      expect(results.length).to eq(2)
      expect(results).to all(include(:pattern_id, :success))
    end
  end

  describe 'CATEGORIES constant' do
    it 'includes all item categories' do
      expected = %i[clothing jewelry weapon consumable furniture misc]
      expect(described_class::CATEGORIES).to eq(expected)
    end
  end

  describe 'IMAGE_STYLES constant' do
    it 'has style for each category' do
      expect(described_class::IMAGE_STYLES[:clothing]).to eq(:item_on_model)
      expect(described_class::IMAGE_STYLES[:jewelry]).to eq(:item_on_black)
      expect(described_class::IMAGE_STYLES[:weapon]).to eq(:item_on_black)
      expect(described_class::IMAGE_STYLES[:furniture]).to eq(:furniture)
    end
  end

  # Note: CATEGORY_CONFIGS is a private constant and tested indirectly
  # through the generate_description methods

  describe 'private methods' do
    describe '.pattern_category' do
      it 'returns clothing for clothing patterns' do
        pattern = double(clothing?: true, jewelry?: false, weapon?: false, consumable?: false)
        result = described_class.send(:pattern_category, pattern)
        expect(result).to eq(:clothing)
      end

      it 'returns jewelry for jewelry patterns' do
        pattern = double(clothing?: false, jewelry?: true, weapon?: false, consumable?: false)
        result = described_class.send(:pattern_category, pattern)
        expect(result).to eq(:jewelry)
      end

      it 'returns weapon for weapon patterns' do
        pattern = double(clothing?: false, jewelry?: false, weapon?: true, consumable?: false)
        result = described_class.send(:pattern_category, pattern)
        expect(result).to eq(:weapon)
      end

      it 'returns consumable for consumable patterns' do
        pattern = double(clothing?: false, jewelry?: false, weapon?: false, consumable?: true)
        result = described_class.send(:pattern_category, pattern)
        expect(result).to eq(:consumable)
      end

      it 'returns misc for unknown patterns' do
        pattern = double(clothing?: false, jewelry?: false, weapon?: false, consumable?: false)
        result = described_class.send(:pattern_category, pattern)
        expect(result).to eq(:misc)
      end
    end
  end
end
