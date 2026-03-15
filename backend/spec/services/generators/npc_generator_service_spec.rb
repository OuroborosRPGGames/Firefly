# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::NPCGeneratorService do
  let(:location) { double('Location', id: 1, name: 'Test City') }
  let(:seed_terms) { %w[weathered mysterious scarred] }

  before do
    allow(SeedTermService).to receive(:for_generation).and_return(seed_terms)
  end

  describe '.generate' do
    let(:name_options) do
      [
        double('NameOption', forename: 'Marcus', surname: 'Thornwood', full_name: 'Marcus Thornwood', gender: :male),
        double('NameOption', forename: 'Elena', surname: 'Blackwood', full_name: 'Elena Blackwood', gender: :female)
      ]
    end

    before do
      allow(NameGeneratorService).to receive(:character_options).and_return(name_options)
      allow(GenerationPipelineService).to receive(:select_best_name).and_return({
        selected: 'Marcus Thornwood',
        reasoning: 'Fits the role well'
      })
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true,
        data: {
          'appearance' => 'A tall man with weathered features.',
          'short_desc' => 'a weathered shopkeeper',
          'personality' => 'Gruff but fair, he treats every customer honestly.'
        }
      })
      allow(GamePrompts).to receive(:get).and_return('Generated prompt')
    end

    it 'generates a complete NPC with name and profile from single call' do
      result = described_class.generate(location: location, role: 'shopkeeper')

      expect(result[:success]).to be_truthy
      expect(result[:name][:full_name]).to eq('Marcus Thornwood')
      expect(result[:appearance]).to include('weathered')
      expect(result[:short_desc]).to eq('a weathered shopkeeper')
      expect(result[:personality]).to include('Gruff')
    end

    it 'includes seed terms in results' do
      result = described_class.generate(location: location, role: 'guard')

      expect(result[:seed_terms]).to eq(seed_terms)
    end

    it 'selects a random role when not specified' do
      result = described_class.generate(location: location)

      expect(result[:role]).not_to be_nil
    end

    context 'when name generation fails' do
      before do
        allow(NameGeneratorService).to receive(:character_options).and_return([])
      end

      it 'returns error' do
        result = described_class.generate(location: location, role: 'merchant')

        expect(result[:success]).to be false
        expect(result[:errors]).to include('No name options generated')
      end
    end

    context 'when profile generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured)
          .and_return({ success: false, error: 'LLM unavailable' })
      end

      it 'returns with error but continues' do
        result = described_class.generate(location: location, role: 'guard')

        expect(result[:errors]).to include('LLM unavailable')
      end
    end

    context 'with portrait generation' do
      before do
        allow(WorldBuilderImageService).to receive(:generate).and_return({
          success: true,
          local_url: '/images/npc_portrait_1.png'
        })
      end

      it 'generates portrait when requested' do
        result = described_class.generate(
          location: location,
          role: 'innkeeper',
          generate_portrait: true
        )

        expect(result[:portrait_url]).to eq('/images/npc_portrait_1.png')
      end
    end

    context 'with schedule generation' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: true,
          content: '[{"time": "6:00", "activity": "Wake up", "location": "Bedroom"}]'
        })
      end

      it 'generates schedule when requested' do
        result = described_class.generate(
          location: location,
          role: 'blacksmith',
          generate_schedule: true
        )

        expect(result[:schedule]).to be_an(Array)
        expect(result[:schedule].first['time']).to eq('6:00')
      end
    end

    context 'with different genders' do
      it 'respects male gender' do
        result = described_class.generate(location: location, role: 'guard', gender: :male)

        expect(result[:name][:full_name]).to eq('Marcus Thornwood')
      end

      it 'respects female gender' do
        allow(GenerationPipelineService).to receive(:select_best_name).and_return({
          selected: 'Elena Blackwood',
          reasoning: 'Fits the role'
        })

        result = described_class.generate(location: location, role: 'healer', gender: :female)

        expect(result[:name][:full_name]).to eq('Elena Blackwood')
      end
    end
  end

  describe '.generate_name' do
    let(:name_options) do
      [
        double('NameOption', forename: 'John', surname: 'Smith', full_name: 'John Smith', gender: :male),
        double('NameOption', forename: 'Jane', surname: 'Doe', full_name: 'Jane Doe', gender: :female)
      ]
    end

    before do
      allow(NameGeneratorService).to receive(:character_options).and_return(name_options)
      allow(GenerationPipelineService).to receive(:select_best_name).and_return({
        selected: 'John Smith',
        reasoning: 'Classic name'
      })
    end

    it 'returns formatted name result' do
      result = described_class.generate_name(gender: :male, culture: :western, role: 'guard')

      expect(result[:success]).to be true
      expect(result[:forename]).to eq('John')
      expect(result[:surname]).to eq('Smith')
      expect(result[:full_name]).to eq('John Smith')
    end

    it 'includes LLM reasoning' do
      result = described_class.generate_name(role: 'merchant')

      expect(result[:reasoning]).to eq('Classic name')
    end

    context 'with no name options' do
      before do
        allow(NameGeneratorService).to receive(:character_options).and_return([])
      end

      it 'returns error' do
        result = described_class.generate_name(role: 'guard')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No name options generated')
      end
    end

    context 'when name generation raises error' do
      before do
        allow(NameGeneratorService).to receive(:character_options).and_raise(StandardError.new('Connection error'))
      end

      it 'returns error with message' do
        result = described_class.generate_name(role: 'merchant')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Name generation failed')
      end
    end
  end

  describe '.generate_character_profile' do
    before do
      allow(GamePrompts).to receive(:get).and_return('Generate character profile')
    end

    context 'with successful structured response' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: true,
          data: {
            'appearance' => 'A broad-shouldered man with calloused hands and a soot-stained apron.',
            'short_desc' => 'A burly, soot-covered blacksmith',
            'personality' => 'Patient and methodical, he takes pride in every piece he forges.'
          }
        })
      end

      it 'returns all three fields from a single call' do
        result = described_class.generate_character_profile(
          name: 'Gareth Ironforge',
          gender: 'male',
          role: 'blacksmith',
          setting: :fantasy,
          seed_terms: %w[sturdy patient]
        )

        expect(result[:success]).to be true
        expect(result[:appearance]).to include('broad-shouldered')
        expect(result[:short_desc]).to start_with('a ')
        expect(result[:personality]).to include('Patient')
      end

      it 'post-processes short_desc to lowercase with a/an prefix' do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: true,
          data: {
            'appearance' => 'Tall.',
            'short_desc' => 'Burly blacksmith',
            'personality' => 'Kind.'
          }
        })

        result = described_class.generate_character_profile(
          name: 'Test', gender: 'male', role: 'blacksmith'
        )

        expect(result[:short_desc]).to eq('a burly blacksmith')
      end

      it 'caps short_desc at 60 characters' do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: true,
          data: {
            'appearance' => 'Tall.',
            'short_desc' => 'a very long description that goes on and on and on and should be truncated at sixty chars',
            'personality' => 'Kind.'
          }
        })

        result = described_class.generate_character_profile(
          name: 'Test', gender: 'male', role: 'blacksmith'
        )

        expect(result[:short_desc].length).to be <= 60
      end
    end

    context 'when generation fails' do
      before do
        allow(GenerationPipelineService).to receive(:generate_structured).and_return({
          success: false, data: nil, error: 'API unavailable'
        })
      end

      it 'returns error' do
        result = described_class.generate_character_profile(
          name: 'Test', gender: 'male', role: 'guard'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('API unavailable')
      end
    end

    it 'uses the character_profile prompt' do
      allow(GenerationPipelineService).to receive(:generate_structured).and_return({
        success: true, data: { 'appearance' => 'x', 'short_desc' => 'a guard', 'personality' => 'y' }
      })

      expect(GamePrompts).to receive(:get).with('npc_generation.character_profile', anything)

      described_class.generate_character_profile(
        name: 'Test', gender: 'male', role: 'guard'
      )
    end

    it 'calls generate_structured with correct tool schema' do
      expect(GenerationPipelineService).to receive(:generate_structured).with(
        hash_including(
          tool_name: 'save_character_profile',
          parameters: hash_including(
            required: %w[appearance short_desc personality]
          )
        )
      ).and_return({
        success: true, data: { 'appearance' => 'x', 'short_desc' => 'a guard', 'personality' => 'y' }
      })

      described_class.generate_character_profile(
        name: 'Test', gender: 'male', role: 'guard'
      )
    end
  end

  describe '.generate_appearance' do
    before do
      allow(GamePrompts).to receive(:get).and_return('Generate appearance for test')
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'A weathered face with deep-set eyes.'
      })
    end

    it 'generates appearance description' do
      result = described_class.generate_appearance(
        name: 'John Smith',
        gender: 'male',
        role: 'blacksmith',
        setting: :fantasy,
        seed_terms: %w[scarred muscular]
      )

      expect(result[:success]).to be true
      expect(result[:content]).to include('weathered')
    end

    it 'uses GamePrompts for prompt generation' do
      expect(GamePrompts).to receive(:get).with('npc_generation.physical_appearance', anything)

      described_class.generate_appearance(
        name: 'Test',
        gender: 'male',
        role: 'guard'
      )
    end
  end

  describe '.generate_personality' do
    before do
      allow(GamePrompts).to receive(:get).and_return('Generate personality')
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'Stoic and reliable, with a hidden warmth.'
      })
    end

    it 'generates personality traits' do
      result = described_class.generate_personality(
        name: 'Marcus',
        role: 'guard',
        setting: :fantasy,
        seed_terms: %w[loyal steadfast]
      )

      expect(result[:success]).to be true
      expect(result[:content]).to include('Stoic')
    end
  end

  describe '.generate_portrait_image' do
    before do
      allow(WorldBuilderImageService).to receive(:generate).and_return({
        success: true,
        url: 'https://example.com/portrait.png',
        local_url: '/images/portraits/npc_1.png'
      })
    end

    it 'generates portrait via WorldBuilderImageService' do
      result = described_class.generate_portrait_image(
        appearance: 'A tall man with gray hair',
        setting: :fantasy
      )

      expect(result[:local_url]).to eq('/images/portraits/npc_1.png')
    end

    it 'passes setting and save_locally option' do
      expect(WorldBuilderImageService).to receive(:generate).with(
        hash_including(
          type: :npc_portrait,
          options: hash_including(setting: :fantasy, save_locally: true)
        )
      )

      described_class.generate_portrait_image(
        appearance: 'Test appearance',
        setting: :fantasy
      )
    end
  end

  describe '.generate_portrait' do
    let(:character) do
      double('Character',
             full_name: 'Test Character',
             long_desc: 'A tall warrior with a scar',
             short_desc: 'Scarred warrior',
             is_female?: false,
             is_male?: true,
             npc_archetype: nil)
    end

    before do
      allow(WorldBuilderImageService).to receive(:generate).and_return({
        success: true,
        local_url: '/images/portrait.png'
      })
    end

    it 'uses existing long_desc for portrait' do
      result = described_class.generate_portrait(character: character)

      expect(WorldBuilderImageService).to have_received(:generate).with(
        hash_including(description: 'A tall warrior with a scar')
      )
      expect(result[:success]).to be true
    end

    context 'when character has no description' do
      let(:character_no_desc) do
        double('Character',
               full_name: 'Mystery Person',
               long_desc: nil,
               short_desc: nil,
               is_female?: false,
               is_male?: false,
               npc_archetype: nil)
      end

      before do
        allow(GamePrompts).to receive(:get).and_return('Generate appearance')
        allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
          success: true,
          content: 'Generated appearance description'
        })
      end

      it 'generates appearance first' do
        result = described_class.generate_portrait(character: character_no_desc)

        expect(result[:success]).to be true
      end
    end

    context 'when appearance generation fails' do
      let(:character_no_desc) do
        double('Character',
               full_name: 'Mystery',
               long_desc: nil,
               short_desc: nil,
               is_female?: true,
               is_male?: false,
               npc_archetype: nil)
      end

      before do
        allow(GamePrompts).to receive(:get).and_return('Prompt')
        allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
          success: false,
          error: 'Failed'
        })
      end

      it 'returns error' do
        result = described_class.generate_portrait(character: character_no_desc)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No appearance description available')
      end
    end
  end

  describe '.generate_daily_schedule' do
    before do
      allow(GamePrompts).to receive(:get).and_return('Generate schedule')
    end

    context 'with valid JSON response' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: true,
          content: '[{"time": "6:00", "activity": "Wake up"}, {"time": "8:00", "activity": "Open shop"}]'
        })
      end

      it 'parses schedule correctly' do
        result = described_class.generate_daily_schedule(
          name: 'Bob',
          role: 'shopkeeper',
          location: location
        )

        expect(result[:success]).to be true
        expect(result[:schedule]).to be_an(Array)
        expect(result[:schedule].length).to eq(2)
      end
    end

    context 'with LLM failure' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: false,
          error: 'Service unavailable'
        })
      end

      it 'returns error' do
        result = described_class.generate_daily_schedule(
          name: 'Bob',
          role: 'guard',
          location: location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Service unavailable')
      end
    end

    context 'with invalid JSON response' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: true,
          content: 'Not valid JSON at all'
        })
      end

      it 'returns format error' do
        result = described_class.generate_daily_schedule(
          name: 'Bob',
          role: 'merchant',
          location: location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Invalid schedule format')
      end
    end

    context 'with malformed JSON response' do
      before do
        allow(GenerationPipelineService).to receive(:generate_simple).and_return({
          success: true,
          content: '[{"time": "6:00", activity: broken}]'
        })
      end

      it 'returns parse error' do
        result = described_class.generate_daily_schedule(
          name: 'Bob',
          role: 'guard',
          location: location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Schedule parse error')
      end
    end
  end

  describe '.generate_description' do
    let(:character) do
      double('Character',
             full_name: 'Test NPC',
             is_female?: false,
             is_male?: true,
             npc_archetype: nil)
    end

    before do
      allow(GamePrompts).to receive(:get).and_return('Generate appearance')
      allow(GenerationPipelineService).to receive(:generate_with_validation).and_return({
        success: true,
        content: 'A grizzled veteran with keen eyes.'
      })
    end

    it 'generates description for existing character' do
      result = described_class.generate_description(character: character)

      expect(result[:success]).to be true
      expect(result[:content]).to include('grizzled')
    end

    it 'uses custom seed terms when provided' do
      custom_terms = %w[elegant refined]
      result = described_class.generate_description(
        character: character,
        options: { seed_terms: custom_terms }
      )

      expect(result[:success]).to be true
    end

    context 'with npc_archetype' do
      let(:archetype) { double('NpcArchetype', name: 'Warrior') }
      let(:character_with_archetype) do
        double('Character',
               full_name: 'Test',
               is_female?: true,
               is_male?: false,
               npc_archetype: archetype)
      end

      it 'uses archetype name as role' do
        expect(GamePrompts).to receive(:get).with(
          'npc_generation.physical_appearance',
          hash_including(role: 'Warrior')
        )

        described_class.generate_description(character: character_with_archetype)
      end
    end
  end

  describe 'NPC_ROLES constant' do
    it 'has service roles' do
      expect(described_class::NPC_ROLES[:service]).to include('shopkeeper', 'innkeeper')
    end

    it 'has guard roles' do
      expect(described_class::NPC_ROLES[:guard]).to include('guard', 'soldier')
    end

    it 'has craft roles' do
      expect(described_class::NPC_ROLES[:craft]).to include('blacksmith', 'tailor')
    end

    it 'has learned roles' do
      expect(described_class::NPC_ROLES[:learned]).to include('scribe', 'healer')
    end

    it 'has all expected categories' do
      expected = %i[service guard craft learned street noble common misc]
      expect(described_class::NPC_ROLES.keys).to match_array(expected)
    end
  end
end
