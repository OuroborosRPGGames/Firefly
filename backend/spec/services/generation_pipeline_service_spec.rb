# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GenerationPipelineService do
  before do
    # Mock LLM::Client for all tests
    allow(LLM::Client).to receive(:generate).and_return({
      success: true,
      text: 'Generated content'
    })
    allow(LLM::Client).to receive(:available?).and_return(true)
  end

  describe 'constants' do
    describe 'MODELS' do
      it 'defines workhorse model configuration' do
        expect(described_class::MODELS[:workhorse]).to include(:provider, :model)
        expect(described_class::MODELS[:workhorse][:provider]).to eq('google_gemini')
      end

      it 'defines writing model configuration' do
        expect(described_class::MODELS[:writing]).to include(:provider, :model)
        expect(described_class::MODELS[:writing][:provider]).to eq('openrouter')
      end

      it 'defines validation model configuration' do
        expect(described_class::MODELS[:validation]).to include(:provider, :model)
      end

      it 'defines selection model configuration' do
        expect(described_class::MODELS[:selection]).to include(:provider, :model)
      end
    end

    describe 'DEFAULT_VALIDATION' do
      it 'defines room_description criteria' do
        expect(described_class::DEFAULT_VALIDATION[:room_description]).to include('2-4 sentences')
      end

      it 'defines item_description criteria' do
        expect(described_class::DEFAULT_VALIDATION[:item_description]).to include('color')
      end

      it 'defines npc_description criteria' do
        expect(described_class::DEFAULT_VALIDATION[:npc_description]).to include('physical appearance')
      end

      it 'defines place_name criteria' do
        expect(described_class::DEFAULT_VALIDATION[:place_name]).to include('plausible')
      end

      it 'defines city_name criteria' do
        expect(described_class::DEFAULT_VALIDATION[:city_name]).to include('pronounceable')
      end
    end
  end

  describe '.generate_with_validation' do
    context 'with successful generation and validation' do
      before do
        # First call: generation
        # Second call: validation
        call_count = 0
        allow(LLM::Client).to receive(:generate) do |**args|
          call_count += 1
          if args[:options]&.dig(:json_mode)
            # Validation response
            { success: true, text: '{"valid": true, "reason": "Content meets criteria"}' }
          else
            # Generation response
            { success: true, text: 'A cozy tavern with warm firelight dancing on wooden walls. The scent of ale fills the air.' }
          end
        end
      end

      it 'returns successful result' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern',
          validation_criteria: 'Must be 2-4 sentences'
        )

        expect(result[:success]).to be true
        expect(result[:content]).not_to be_nil
      end

      it 'marks content as validated' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern',
          validation_criteria: 'Must be 2-4 sentences'
        )

        expect(result[:validated]).to be true
      end

      it 'tracks attempt count' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern'
        )

        expect(result[:attempts]).to eq(1)
      end
    end

    context 'when generation fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })
      end

      it 'returns failure result' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern'
        )

        expect(result[:success]).to be false
        expect(result[:content]).to be_nil
      end

      it 'includes error message' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern'
        )

        expect(result[:errors]).to include('API timeout')
      end
    end

    context 'when validation fails' do
      before do
        call_count = 0
        allow(LLM::Client).to receive(:generate) do |**args|
          call_count += 1
          if args[:options]&.dig(:json_mode)
            # Validation always fails
            { success: true, text: '{"valid": false, "reason": "Too short", "issues": ["Missing atmosphere"]}' }
          else
            # Generation succeeds
            { success: true, text: 'A tavern.' }
          end
        end
      end

      it 'retries with workhorse model' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern',
          validation_criteria: 'Must be detailed',
          max_retries: 2
        )

        # Should have attempted generation + retries
        expect(result[:attempts]).to be > 1
      end

      it 'returns best effort content if validation never passes' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a tavern',
          validation_criteria: 'Must be detailed',
          max_retries: 1
        )

        expect(result[:success]).to be true
        expect(result[:validated]).to be false
        expect(result[:content]).not_to be_nil
      end
    end

    context 'with content_type for default validation' do
      it 'uses default validation for room_description' do
        result = described_class.generate_with_validation(
          prompt: 'Describe a room',
          content_type: :room_description
        )

        expect(result[:success]).to be true
      end
    end

    context 'without validation criteria' do
      it 'returns content without validation step' do
        result = described_class.generate_with_validation(
          prompt: 'Generate text'
        )

        expect(result[:success]).to be true
        expect(result[:content]).not_to be_nil
      end
    end
  end

  describe '.generate_simple' do
    it 'generates content with workhorse model' do
      result = described_class.generate_simple(prompt: 'Test prompt')

      expect(result[:success]).to be true
      expect(result[:content]).not_to be_nil
      expect(result[:model_used]).to eq(described_class::MODELS[:workhorse][:model])
    end

    context 'when generation fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Service unavailable'
        })
      end

      it 'returns failure result' do
        result = described_class.generate_simple(prompt: 'Test')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Service unavailable')
      end
    end
  end

  describe '.generate_description' do
    it 'uses writing model for high-quality output' do
      result = described_class.generate_description(prompt: 'Describe a sunset')

      expect(result[:success]).to be true
      expect(result[:model_used]).to eq(described_class::MODELS[:writing][:model])
    end
  end

  describe '.select_best_name' do
    context 'with empty options' do
      it 'returns error' do
        result = described_class.select_best_name(options: [])

        expect(result[:success]).to be false
        expect(result[:error]).to include('No options')
      end
    end

    context 'with single option' do
      it 'returns that option' do
        result = described_class.select_best_name(options: ['The Golden Dragon'])

        expect(result[:success]).to be true
        expect(result[:selected]).to eq('The Golden Dragon')
        expect(result[:reasoning]).to include('Only one option')
      end
    end

    context 'with multiple options' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"selected": "The Gilded Wyrm", "reasoning": "Most evocative name"}'
        })
      end

      it 'uses LLM to select best option' do
        result = described_class.select_best_name(
          options: ['The Golden Dragon', "Dragon's Rest", 'The Gilded Wyrm'],
          context: { setting: 'fantasy', place_type: 'tavern' }
        )

        expect(result[:success]).to be true
        expect(result[:selected]).to eq('The Gilded Wyrm')
        expect(result[:reasoning]).to eq('Most evocative name')
      end
    end

    context 'when LLM returns non-matching selection' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"selected": "Different Name", "reasoning": "It sounds better"}'
        })
      end

      it 'finds closest match or uses first option' do
        result = described_class.select_best_name(
          options: ['The Golden Dragon', "Dragon's Rest"]
        )

        expect(result[:success]).to be true
        # Falls back to first option if no match found
        expect(result[:selected]).to eq('The Golden Dragon')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API error'
        })
      end

      it 'falls back to first option' do
        result = described_class.select_best_name(
          options: ['Option A', 'Option B']
        )

        expect(result[:success]).to be true
        expect(result[:selected]).to eq('Option A')
        expect(result[:reasoning]).to include('failed')
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'Not valid JSON at all'
        })
      end

      it 'falls back to first option' do
        result = described_class.select_best_name(
          options: ['Fallback Option', 'Other Option']
        )

        expect(result[:success]).to be true
        expect(result[:selected]).to eq('Fallback Option')
      end
    end
  end

  describe '.validate_content' do
    context 'when content passes validation' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"valid": true, "reason": "All criteria met"}'
        })
      end

      it 'returns valid result' do
        result = described_class.validate_content(
          'A detailed room description with atmosphere and mood.',
          'Must describe atmosphere'
        )

        expect(result[:valid]).to be true
        expect(result[:reason]).to eq('All criteria met')
      end
    end

    context 'when content fails validation' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"valid": false, "reason": "Missing details", "issues": ["No color mentioned", "Too vague"]}'
        })
      end

      it 'returns invalid result with issues' do
        result = described_class.validate_content(
          'A room.',
          'Must be detailed with colors'
        )

        expect(result[:valid]).to be false
        expect(result[:reason]).to eq('Missing details')
        expect(result[:issues]).to include('No color mentioned')
      end
    end

    context 'when validation service is unavailable' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Service down'
        })
      end

      it 'assumes content is valid' do
        result = described_class.validate_content(
          'Some content',
          'Some criteria'
        )

        expect(result[:valid]).to be true
        expect(result[:reason]).to include('unavailable')
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'Invalid JSON response'
        })
      end

      it 'assumes content is valid' do
        result = described_class.validate_content(
          'Some content',
          'Some criteria'
        )

        expect(result[:valid]).to be true
        expect(result[:reason]).to include('Parse error')
      end
    end

    context 'with alternative response formats' do
      it 'accepts "passes" key' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"passes": true}'
        })

        result = described_class.validate_content('content', 'criteria')
        expect(result[:valid]).to be true
      end

      it 'accepts "meets_criteria" key' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"meets_criteria": true}'
        })

        result = described_class.validate_content('content', 'criteria')
        expect(result[:valid]).to be true
      end
    end
  end

  describe '.generate_structured' do
    let(:tool_params) do
      {
        prompt: 'Extract room data',
        tool_name: 'extract_room',
        tool_description: 'Extract structured room data',
        parameters: {
          type: 'object',
          properties: { name: { type: 'string' }, size: { type: 'integer' } },
          required: ['name']
        }
      }
    end

    context 'when model returns tool call' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: nil,
          tool_calls: [{ id: 'call_1', name: 'extract_room', arguments: { 'name' => 'Grand Hall', 'size' => 100 } }]
        })
      end

      it 'returns structured data from tool call' do
        result = described_class.generate_structured(**tool_params)
        expect(result[:success]).to be true
        expect(result[:data]).to eq({ 'name' => 'Grand Hall', 'size' => 100 })
      end

      it 'includes model_used' do
        result = described_class.generate_structured(**tool_params)
        expect(result[:model_used]).to eq(described_class::MODELS[:workhorse][:model])
      end

      it 'passes tools to LLM::Client' do
        expect(LLM::Client).to receive(:generate).with(hash_including(
          tools: [{
            name: 'extract_room',
            description: 'Extract structured room data',
            parameters: tool_params[:parameters]
          }]
        )).and_return({ success: true, text: nil, tool_calls: [{ id: '1', name: 'extract_room', arguments: {} }] })

        described_class.generate_structured(**tool_params)
      end
    end

    context 'when model returns text instead of tool call (fallback)' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"name": "Fallback Room", "size": 50}',
          tool_calls: nil
        })
      end

      it 'parses JSON from text as fallback' do
        result = described_class.generate_structured(**tool_params)
        expect(result[:success]).to be true
        expect(result[:data]).to eq({ 'name' => 'Fallback Room', 'size' => 50 })
      end
    end

    context 'when model returns unparseable text' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'Not JSON at all',
          tool_calls: nil
        })
      end

      it 'returns failure' do
        result = described_class.generate_structured(**tool_params)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No tool call')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })
      end

      it 'returns failure with error' do
        result = described_class.generate_structured(**tool_params)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('API timeout')
      end
    end

    context 'with custom model_key' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: nil,
          tool_calls: [{ id: '1', name: 'extract_room', arguments: { 'name' => 'Room' } }]
        })
      end

      it 'uses specified model configuration' do
        expect(LLM::Client).to receive(:generate).with(hash_including(
          provider: described_class::MODELS[:writing][:provider],
          model: described_class::MODELS[:writing][:model]
        )).and_return({ success: true, text: nil, tool_calls: [{ id: '1', name: 'x', arguments: {} }] })

        described_class.generate_structured(**tool_params, model_key: :writing)
      end
    end

    context 'with unknown model_key' do
      it 'returns failure' do
        result = described_class.generate_structured(**tool_params, model_key: :nonexistent)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Unknown model key')
      end
    end
  end

  describe '.available?' do
    it 'delegates to LLM::Client.available?' do
      expect(LLM::Client).to receive(:available?).and_return(true)
      expect(described_class.available?).to be true
    end
  end

  describe '.format_seed_instructions' do
    before do
      allow(SeedTermService).to receive(:for_generation).and_return(['sunset', 'amber', 'twilight'])
    end

    it 'formats seed terms with instructions' do
      result = described_class.format_seed_instructions(:room, count: 3)

      expect(result).to include('sunset')
      expect(result).to include('amber')
      expect(result).to include('twilight')
    end

    context 'when no seeds available' do
      before do
        allow(SeedTermService).to receive(:for_generation).and_return([])
      end

      it 'returns empty string' do
        result = described_class.format_seed_instructions(:room)
        expect(result).to eq('')
      end
    end
  end

  describe '.build_prompt_with_seeds' do
    before do
      allow(SeedTermService).to receive(:for_generation).and_return(['mystic', 'ancient'])
    end

    it 'appends seed instructions to base prompt' do
      result = described_class.build_prompt_with_seeds(
        base_prompt: 'Describe a forest',
        task_type: :room,
        seed_count: 2
      )

      expect(result).to include('Describe a forest')
      expect(result).to include('mystic')
    end

    context 'when no seeds available' do
      before do
        allow(SeedTermService).to receive(:for_generation).and_return([])
      end

      it 'returns base prompt unchanged' do
        result = described_class.build_prompt_with_seeds(
          base_prompt: 'Base prompt',
          task_type: :room
        )

        expect(result).to eq('Base prompt')
      end
    end
  end

  describe 'retry logic' do
    context 'when initial generation passes validation' do
      before do
        call_count = 0
        allow(LLM::Client).to receive(:generate) do |**args|
          call_count += 1
          if args[:options]&.dig(:json_mode)
            { success: true, text: '{"valid": true}' }
          else
            { success: true, text: 'Good content' }
          end
        end
      end

      it 'does not retry' do
        result = described_class.generate_with_validation(
          prompt: 'Test',
          validation_criteria: 'Must be good',
          max_retries: 3
        )

        expect(result[:attempts]).to eq(1)
      end
    end

    context 'when retry succeeds' do
      before do
        call_count = 0
        allow(LLM::Client).to receive(:generate) do |**args|
          call_count += 1
          if args[:options]&.dig(:json_mode)
            # Validation: fail first, pass second
            if call_count <= 2
              { success: true, text: '{"valid": false, "reason": "Too short"}' }
            else
              { success: true, text: '{"valid": true}' }
            end
          else
            # Generation
            { success: true, text: call_count <= 1 ? 'Short.' : 'A much longer and better response.' }
          end
        end
      end

      it 'returns success with retry count' do
        result = described_class.generate_with_validation(
          prompt: 'Test',
          validation_criteria: 'Must be detailed',
          max_retries: 2
        )

        expect(result[:success]).to be true
        expect(result[:validated]).to be true
        expect(result[:attempts]).to be > 1
      end
    end
  end

  describe 'error handling' do
    it 'handles StandardError in select_best_name' do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: '{"selected": null}'  # Will cause issues when processing
      })

      result = described_class.select_best_name(options: ['A', 'B'])

      # Should not raise, should fall back gracefully
      expect(result[:success]).to be true
    end
  end
end
