# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TriggerLLMMatcherService do
  describe 'constants' do
    it 'defines LLM_MODEL' do
      expect(described_class::LLM_MODEL).to eq('gemini-3-flash-preview')
    end

    it 'defines LLM_PROVIDER' do
      expect(described_class::LLM_PROVIDER).to eq('google_gemini')
    end
  end

  describe '.check_match' do
    let(:valid_response) do
      {
        success: true,
        text: { matches: true, confidence: 0.85, reasoning: 'Strong match found' }.to_json
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return(valid_response)
      allow(GamePrompts).to receive(:get).and_return('Test prompt')
    end

    context 'with valid inputs' do
      it 'returns matched result when confidence exceeds threshold' do
        result = described_class.check_match(
          content: 'The guard draws his sword',
          prompt: 'Combat behavior'
        )

        expect(result[:matched]).to be true
        expect(result[:confidence]).to eq(0.85)
        expect(result[:reasoning]).to eq('Strong match found')
      end

      it 'includes confidence details in response' do
        result = described_class.check_match(
          content: 'The guard draws his sword',
          prompt: 'Combat behavior'
        )

        expect(result[:details]).to include('85.0%')
        expect(result[:details]).to include('70.0%') # default threshold
      end

      it 'uses custom threshold' do
        result = described_class.check_match(
          content: 'Test content',
          prompt: 'Test condition',
          threshold: 0.9
        )

        # 0.85 confidence < 0.9 threshold, so not matched
        expect(result[:matched]).to be false
        expect(result[:details]).to include('90.0%')
      end

      it 'calls LLM::Client with correct parameters' do
        expect(LLM::Client).to receive(:generate).with(
          hash_including(
            model: 'gemini-3-flash-preview',
            provider: 'google_gemini',
            json_mode: true
          )
        )

        described_class.check_match(content: 'Test', prompt: 'Condition')
      end

      it 'uses GamePrompts to build prompt' do
        expect(GamePrompts).to receive(:get).with(
          'triggers.behavior_matching',
          content: 'Guard attacks',
          trigger_condition: 'Combat detected'
        )

        described_class.check_match(content: 'Guard attacks', prompt: 'Combat detected')
      end
    end

    context 'with empty inputs' do
      it 'returns no match for nil content' do
        result = described_class.check_match(content: nil, prompt: 'Test')

        expect(result[:matched]).to be false
        expect(result[:confidence]).to eq(0.0)
        expect(result[:reasoning]).to eq('Empty content')
      end

      it 'returns no match for empty content' do
        result = described_class.check_match(content: '   ', prompt: 'Test')

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to eq('Empty content')
      end

      it 'returns no match for nil prompt' do
        result = described_class.check_match(content: 'Test', prompt: nil)

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to eq('Empty prompt')
      end

      it 'returns no match for empty prompt' do
        result = described_class.check_match(content: 'Test', prompt: '')

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to eq('Empty prompt')
      end
    end

    context 'when LLM returns non-matching response' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: false, confidence: 0.2, reasoning: 'No relevant match' }.to_json
        })
      end

      it 'returns no match' do
        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:matched]).to be false
        expect(result[:confidence]).to eq(0.2)
      end
    end

    context 'when confidence is below threshold' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: true, confidence: 0.5, reasoning: 'Weak match' }.to_json
        })
      end

      it 'returns no match even if LLM says matches: true' do
        result = described_class.check_match(
          content: 'Test',
          prompt: 'Condition',
          threshold: 0.7
        )

        expect(result[:matched]).to be false
        expect(result[:confidence]).to eq(0.5)
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })
      end

      it 'returns no match with error reason' do
        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to eq('LLM error: API timeout')
      end
    end

    context 'when LLM returns invalid JSON' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'not valid json'
        })
      end

      it 'returns no match with parse error' do
        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to include('Failed to parse LLM response')
      end
    end

    context 'when exception occurs' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError, 'Network error')
      end

      it 'returns no match with error message' do
        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:matched]).to be false
        expect(result[:reasoning]).to eq('Error: Network error')
      end
    end

    context 'with markdown-wrapped JSON response' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: "```json\n{\"matches\": true, \"confidence\": 0.9, \"reasoning\": \"Match found\"}\n```"
        })
      end

      it 'strips markdown fences and parses JSON' do
        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:matched]).to be true
        expect(result[:confidence]).to eq(0.9)
      end
    end

    context 'with confidence clamping' do
      it 'clamps confidence above 1.0 to 1.0' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: true, confidence: 1.5, reasoning: 'Very confident' }.to_json
        })

        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:confidence]).to eq(1.0)
      end

      it 'clamps confidence below 0.0 to 0.0' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: false, confidence: -0.5, reasoning: 'Negative confidence' }.to_json
        })

        result = described_class.check_match(content: 'Test', prompt: 'Condition')

        expect(result[:confidence]).to eq(0.0)
      end
    end

    context 'with edge case threshold values' do
      it 'matches at exact threshold' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: true, confidence: 0.7, reasoning: 'Exact threshold' }.to_json
        })

        result = described_class.check_match(
          content: 'Test',
          prompt: 'Condition',
          threshold: 0.7
        )

        expect(result[:matched]).to be true
      end

      it 'works with threshold of 0.0' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: true, confidence: 0.01, reasoning: 'Tiny confidence' }.to_json
        })

        result = described_class.check_match(
          content: 'Test',
          prompt: 'Condition',
          threshold: 0.0
        )

        expect(result[:matched]).to be true
      end

      it 'works with threshold of 1.0' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { matches: true, confidence: 0.99, reasoning: 'High confidence' }.to_json
        })

        result = described_class.check_match(
          content: 'Test',
          prompt: 'Condition',
          threshold: 1.0
        )

        expect(result[:matched]).to be false
      end
    end
  end

  describe 'private methods' do
    describe '#no_match' do
      it 'returns proper structure' do
        result = described_class.send(:no_match, 'Test reason')

        expect(result[:matched]).to be false
        expect(result[:confidence]).to eq(0.0)
        expect(result[:reasoning]).to eq('Test reason')
        expect(result[:details]).to eq('Test reason')
      end
    end

    describe '#build_prompt' do
      it 'calls GamePrompts with correct parameters' do
        expect(GamePrompts).to receive(:get).with(
          'triggers.behavior_matching',
          content: 'The content',
          trigger_condition: 'The condition'
        )

        described_class.send(:build_prompt, 'The content', 'The condition')
      end
    end
  end
end
