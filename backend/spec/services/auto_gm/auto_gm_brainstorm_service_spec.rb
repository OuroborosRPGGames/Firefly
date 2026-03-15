# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmBrainstormService do
  include_context 'auto_gm_setup'

  let(:context) do
    {
      room_context: {
        name: 'Test Room',
        description: 'A mysterious place',
        location_name: 'Test Location'
      },
      participant_context: [
        { name: 'Test Hero', race: 'Human', char_class: 'Fighter', level: 5, background: 'Soldier' }
      ],
      nearby_locations: [
        { location_name: 'Cave', room_name: 'Dark Cave', type: 'cave', distance: 3 }
      ],
      nearby_memories: [
        { summary: 'A battle occurred here', characters_involved: ['Guard'] }
      ],
      character_memories: [],
      local_npcs: []
    }
  end

  describe 'BRAINSTORM_MODELS' do
    it 'has creative_a model' do
      expect(described_class::BRAINSTORM_MODELS[:creative_a]).to be_a(Hash)
      expect(described_class::BRAINSTORM_MODELS[:creative_a][:provider]).to eq('openrouter')
    end

    it 'has creative_b model' do
      expect(described_class::BRAINSTORM_MODELS[:creative_b]).to be_a(Hash)
      expect(described_class::BRAINSTORM_MODELS[:creative_b][:provider]).to eq('openai')
    end
  end

  describe '.brainstorm' do
    let(:request_a) do
      double('LLMRequest',
             status: 'completed',
             response_text: 'Creative idea A: A mysterious artifact...',
             error_message: nil,
             parsed_context: { 'model_key' => 'creative_a' })
    end
    let(:request_b) do
      double('LLMRequest',
             status: 'completed',
             response_text: 'Creative idea B: An ancient temple...',
             error_message: nil,
             parsed_context: { 'model_key' => 'creative_b' })
    end
    let(:batch) do
      double('LlmBatch', wait!: true, results: [request_a, request_b])
    end

    before do
      allow(SeedTermService).to receive(:for_generation).and_return(['mystery', 'artifact', 'ancient'])
      allow(LLM::Client).to receive(:batch_submit).and_return(batch)
    end

    context 'when both models succeed' do
      it 'returns success true' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:success]).to be true
      end

      it 'includes outputs from both models' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:outputs][:creative_a]).to include('Creative idea A')
        expect(result[:outputs][:creative_b]).to include('Creative idea B')
      end

      it 'includes seed_terms' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:seed_terms]).to eq(['mystery', 'artifact', 'ancient'])
      end

      it 'returns empty errors array' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:errors]).to be_empty
      end

      it 'submits batch with correct request structure' do
        expect(LLM::Client).to receive(:batch_submit).with(
          array_including(
            hash_including(provider: 'openrouter', context: { model_key: 'creative_a' }),
            hash_including(provider: 'openai', context: { model_key: 'creative_b' })
          )
        ).and_return(batch)

        described_class.brainstorm(session: session, context: context)
      end
    end

    context 'when one model fails' do
      let(:request_b_failed) do
        double('LLMRequest',
               status: 'failed',
               response_text: nil,
               error_message: 'Model B failed',
               parsed_context: { 'model_key' => 'creative_b' })
      end
      let(:batch) do
        double('LlmBatch', wait!: true, results: [request_a, request_b_failed])
      end

      it 'still returns success if at least one output' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:success]).to be true
      end

      it 'includes error in errors array' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:errors]).not_to be_empty
        expect(result[:errors].first).to include('Model B failed')
      end
    end

    context 'when both models fail' do
      let(:request_a_failed) do
        double('LLMRequest',
               status: 'failed',
               response_text: nil,
               error_message: 'Failed A',
               parsed_context: { 'model_key' => 'creative_a' })
      end
      let(:request_b_failed) do
        double('LLMRequest',
               status: 'failed',
               response_text: nil,
               error_message: 'Failed B',
               parsed_context: { 'model_key' => 'creative_b' })
      end
      let(:batch) do
        double('LlmBatch', wait!: true, results: [request_a_failed, request_b_failed])
      end

      it 'returns success false' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:success]).to be false
      end

      it 'returns empty outputs' do
        result = described_class.brainstorm(session: session, context: context)
        expect(result[:outputs]).to be_empty
      end
    end

    context 'with custom seed terms' do
      it 'uses provided seed terms' do
        custom_terms = ['dragon', 'treasure', 'princess']
        result = described_class.brainstorm(
          session: session,
          context: context,
          options: { seed_terms: custom_terms }
        )
        expect(result[:seed_terms]).to eq(custom_terms)
      end
    end
  end

  describe '.brainstorm_single' do
    before do
      allow(SeedTermService).to receive(:for_generation).and_return(['mystery'])
    end

    context 'with valid model key' do
      it 'returns result from creative_a' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'Single model output'
        })

        result = described_class.brainstorm_single(
          session: session,
          context: context,
          model_key: :creative_a
        )

        expect(result[:success]).to be true
        expect(result[:output]).to eq('Single model output')
      end

      it 'includes model name in result' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'Output'
        })

        result = described_class.brainstorm_single(
          session: session,
          context: context,
          model_key: :creative_a
        )

        expect(result[:model]).to eq('moonshotai/kimi-k2-0905')
      end
    end

    context 'with invalid model key' do
      it 'returns error' do
        result = described_class.brainstorm_single(
          session: session,
          context: context,
          model_key: :invalid_model
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown model key')
      end
    end

    context 'when LLM call fails' do
      it 'returns error from LLM' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })

        result = described_class.brainstorm_single(
          session: session,
          context: context,
          model_key: :creative_a
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('API timeout')
      end
    end
  end

  describe '.models_available?' do
    before do
      allow(AIProviderService).to receive(:provider_available?).with('openrouter').and_return(true)
      allow(AIProviderService).to receive(:provider_available?).with('openai').and_return(false)
    end

    it 'returns hash with availability status' do
      result = described_class.models_available?

      expect(result[:creative_a]).to be true
      expect(result[:creative_b]).to be false
    end
  end

  describe 'private methods' do
    describe '#build_prompt' do
      before do
        allow(GamePrompts).to receive(:get).and_return('Generated prompt')
      end

      it 'calls GamePrompts with correct key' do
        expect(GamePrompts).to receive(:get).with('auto_gm.brainstorm', anything)
        described_class.send(:build_prompt, session, context, ['seed1'])
      end

      it 'includes location name' do
        expect(GamePrompts).to receive(:get).with(
          'auto_gm.brainstorm',
          hash_including(location_name: 'Test Location')
        )
        described_class.send(:build_prompt, session, context, ['seed1'])
      end

      it 'includes seed terms' do
        expect(GamePrompts).to receive(:get).with(
          'auto_gm.brainstorm',
          hash_including(seed_terms: 'seed1, seed2')
        )
        described_class.send(:build_prompt, session, context, ['seed1', 'seed2'])
      end
    end

    describe '#format_participants' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_participants, [])
        expect(result).to eq('No characters present.')
      end

      it 'formats participant info' do
        participants = [
          { name: 'Hero', race: 'Elf', char_class: 'Mage', level: 10 }
        ]
        result = described_class.send(:format_participants, participants)
        expect(result).to include('Hero')
        expect(result).to include('Elf')
        expect(result).to include('Mage')
        expect(result).to include('level 10')
      end
    end

    describe '#format_locations' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_locations, [])
        expect(result).to eq('No interesting locations found nearby.')
      end

      it 'formats location info' do
        locations = [
          { location_name: 'Mountain', room_name: 'Cave Entrance', type: 'cave', distance: 5 }
        ]
        result = described_class.send(:format_locations, locations)
        expect(result).to include('Mountain')
        expect(result).to include('Cave Entrance')
        expect(result).to include('5 rooms away')
      end
    end

    describe '#format_memories' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_memories, [])
        expect(result).to eq('No relevant memories.')
      end

      it 'formats memory info' do
        memories = [
          { summary: 'Battle happened', characters_involved: ['Guard', 'Hero'] }
        ]
        result = described_class.send(:format_memories, memories)
        expect(result).to include('Battle happened')
        expect(result).to include('Guard')
        expect(result).to include('Hero')
      end
    end

    describe '#format_npcs' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_npcs, [])
        expect(result).to eq('No NPCs nearby.')
      end

      it 'formats NPC info' do
        npcs = [
          { name: 'Guard', archetype: 'soldier', is_in_starting_room: true }
        ]
        result = described_class.send(:format_npcs, npcs)
        expect(result).to include('Guard')
        expect(result).to include('soldier')
        expect(result).to include('here')
      end

      it 'shows nearby for NPCs not in starting room' do
        npcs = [
          { name: 'Merchant', archetype: 'trader', is_in_starting_room: false }
        ]
        result = described_class.send(:format_npcs, npcs)
        expect(result).to include('nearby')
      end
    end
  end
end
