# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbuseDetectionService do
  describe 'constants' do
    it 'defines GEMINI_MODEL' do
      expect(described_class::GEMINI_MODEL).to eq('gemini-3.1-flash-lite-preview')
    end

    it 'defines GEMINI_PROVIDER' do
      expect(described_class::GEMINI_PROVIDER).to eq('google_gemini')
    end

    it 'defines CLAUDE_MODEL' do
      expect(described_class::CLAUDE_MODEL).to eq('claude-opus-4-6')
    end

    it 'defines CLAUDE_PROVIDER' do
      expect(described_class::CLAUDE_PROVIDER).to eq('anthropic')
    end
  end

  describe '.gemini_check' do
    let(:check) do
      double('AbuseCheck',
        message_type: 'say',
        message_content: 'Hello world'
      )
    end

    before do
      allow(GamePrompts).to receive(:get).and_return('Test prompt')
    end

    context 'when API call succeeds' do
      let(:json_response) do
        '{"flagged": false, "confidence": 0.1, "reasoning": "Normal greeting", "category": "none"}'
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: json_response
        })
      end

      it 'calls TextGenerationService with correct parameters' do
        expect(LLM::Client).to receive(:generate).with(
          prompt: 'Test prompt',
          model: 'gemini-3.1-flash-lite-preview',
          provider: 'google_gemini',
          json_mode: true,
          options: {
            max_tokens: 500,
            temperature: 0.1
          }
        )

        described_class.gemini_check(check)
      end

      it 'returns parsed result' do
        result = described_class.gemini_check(check)

        expect(result[:flagged]).to be false
        expect(result[:confidence]).to eq(0.1)
        expect(result[:reasoning]).to eq('Normal greeting')
        expect(result[:category]).to eq('none')
      end
    end

    context 'when content is flagged' do
      let(:json_response) do
        '{"flagged": true, "confidence": 0.85, "reasoning": "Contains harassment", "category": "harassment"}'
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: json_response
        })
      end

      it 'returns flagged: true' do
        result = described_class.gemini_check(check)

        expect(result[:flagged]).to be true
        expect(result[:confidence]).to eq(0.85)
        expect(result[:category]).to eq('harassment')
      end
    end

    context 'when API call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'API timeout'
        })
      end

      it 'returns default unflagged result' do
        result = described_class.gemini_check(check)

        expect(result[:flagged]).to be false
        expect(result[:confidence]).to eq(0.0)
        expect(result[:reasoning]).to include('API error')
        expect(result[:category]).to eq('none')
      end
    end

    context 'when exception is raised' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError.new('Network error'))
      end

      it 'returns default unflagged result' do
        result = described_class.gemini_check(check)

        expect(result[:flagged]).to be false
        expect(result[:reasoning]).to include('Exception')
      end
    end

    context 'when response contains markdown code block' do
      let(:json_response) do
        "```json\n{\"flagged\": true, \"confidence\": 0.9, \"reasoning\": \"Test\", \"category\": \"spam\"}\n```"
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: json_response
        })
      end

      it 'extracts JSON from code block' do
        result = described_class.gemini_check(check)

        expect(result[:flagged]).to be true
        expect(result[:category]).to eq('spam')
      end
    end
  end

  describe '.claude_verify' do
    let(:check) do
      double('AbuseCheck',
        message_type: 'say',
        message_content: 'Harassment content',
        abuse_category: 'harassment',
        gemini_confidence: 0.85,
        gemini_reasoning: 'Contains targeted harassment',
        parsed_context: {
          'room_name' => 'Test Room',
          'recent_messages' => ['msg1', 'msg2']
        }
      )
    end

    before do
      allow(GamePrompts).to receive(:get).and_return('Verification prompt')
    end

    context 'when API call succeeds and confirms' do
      let(:json_response) do
        '{"confirmed": true, "confidence": 0.95, "reasoning": "Verified harassment", "category": "harassment", "severity": "high", "recommended_action": "warn"}'
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: json_response
        })
      end

      it 'calls TextGenerationService with correct parameters' do
        expect(LLM::Client).to receive(:generate).with(
          prompt: 'Verification prompt',
          model: 'claude-opus-4-6',
          provider: 'anthropic',
          json_mode: true,
          options: {
            max_tokens: 1000,
            temperature: 0.0
          }
        )

        described_class.claude_verify(check)
      end

      it 'returns confirmed result' do
        result = described_class.claude_verify(check)

        expect(result[:confirmed]).to be true
        expect(result[:confidence]).to eq(0.95)
        expect(result[:category]).to eq('harassment')
        expect(result[:severity]).to eq('high')
        expect(result[:recommended_action]).to eq('warn')
      end
    end

    context 'when API call succeeds but does not confirm' do
      let(:json_response) do
        '{"confirmed": false, "confidence": 0.2, "reasoning": "IC conflict, not OOC", "category": "false_positive", "severity": "low"}'
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: json_response
        })
      end

      it 'returns unconfirmed result' do
        result = described_class.claude_verify(check)

        expect(result[:confirmed]).to be false
        expect(result[:category]).to eq('false_positive')
      end
    end

    context 'when API call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Rate limited'
        })
      end

      it 'returns default unconfirmed result' do
        result = described_class.claude_verify(check)

        expect(result[:confirmed]).to be false
        expect(result[:reasoning]).to include('API error')
        expect(result[:category]).to eq('false_positive')
        expect(result[:severity]).to eq('low')
      end
    end

    context 'when exception is raised' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError.new('Timeout'))
      end

      it 'returns default unconfirmed result' do
        result = described_class.claude_verify(check)

        expect(result[:confirmed]).to be false
        expect(result[:reasoning]).to include('Exception')
      end
    end

    context 'with empty recent messages' do
      let(:check_no_messages) do
        double('AbuseCheck',
          message_type: 'say',
          message_content: 'Test',
          abuse_category: 'spam',
          gemini_confidence: 0.5,
          gemini_reasoning: 'Spam detection',
          parsed_context: {
            'room_name' => 'Test Room',
            'recent_messages' => nil
          }
        )
      end

      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"confirmed": false, "confidence": 0.1, "reasoning": "test", "category": "none", "severity": "low"}'
        })
      end

      it 'handles nil recent messages' do
        result = described_class.claude_verify(check_no_messages)
        expect(result[:confirmed]).to be false
      end
    end
  end

  describe 'private methods' do
    describe '#extract_json' do
      it 'parses plain JSON' do
        json = '{"test": true}'
        result = described_class.send(:extract_json, json)
        expect(result['test']).to be true
      end

      it 'extracts JSON from markdown code block' do
        text = "Some text\n```json\n{\"test\": true}\n```\nMore text"
        result = described_class.send(:extract_json, text)
        expect(result['test']).to be true
      end

      it 'extracts JSON from code block without language' do
        text = "```\n{\"test\": true}\n```"
        result = described_class.send(:extract_json, text)
        expect(result['test']).to be true
      end

      it 'finds JSON object in text' do
        text = "Here is the result: {\"test\": true} - done"
        result = described_class.send(:extract_json, text)
        expect(result['test']).to be true
      end
    end

    describe '#normalize_category' do
      it 'returns valid category unchanged' do
        expect(described_class.send(:normalize_category, 'harassment')).to eq('harassment')
        expect(described_class.send(:normalize_category, 'hate_speech')).to eq('hate_speech')
        expect(described_class.send(:normalize_category, 'threats')).to eq('threats')
        expect(described_class.send(:normalize_category, 'doxxing')).to eq('doxxing')
        expect(described_class.send(:normalize_category, 'spam')).to eq('spam')
        expect(described_class.send(:normalize_category, 'csam')).to eq('csam')
        expect(described_class.send(:normalize_category, 'false_positive')).to eq('false_positive')
        expect(described_class.send(:normalize_category, 'none')).to eq('none')
      end

      it 'normalizes case' do
        expect(described_class.send(:normalize_category, 'HARASSMENT')).to eq('harassment')
        expect(described_class.send(:normalize_category, 'Spam')).to eq('spam')
      end

      it 'returns other for unknown category' do
        expect(described_class.send(:normalize_category, 'unknown')).to eq('other')
        expect(described_class.send(:normalize_category, 'invalid')).to eq('other')
      end

      it 'strips whitespace' do
        expect(described_class.send(:normalize_category, '  spam  ')).to eq('spam')
      end
    end

    describe '#normalize_severity' do
      it 'returns valid severity unchanged' do
        expect(described_class.send(:normalize_severity, 'low')).to eq('low')
        expect(described_class.send(:normalize_severity, 'medium')).to eq('medium')
        expect(described_class.send(:normalize_severity, 'high')).to eq('high')
        expect(described_class.send(:normalize_severity, 'critical')).to eq('critical')
      end

      it 'normalizes case' do
        expect(described_class.send(:normalize_severity, 'HIGH')).to eq('high')
        expect(described_class.send(:normalize_severity, 'Low')).to eq('low')
      end

      it 'returns medium for unknown severity' do
        expect(described_class.send(:normalize_severity, 'unknown')).to eq('medium')
        expect(described_class.send(:normalize_severity, 'invalid')).to eq('medium')
      end
    end

    describe '#format_recent_messages' do
      it 'formats messages with numbers' do
        messages = ['Hello', 'World', 'Test']
        result = described_class.send(:format_recent_messages, messages)

        expect(result).to include('1. Hello')
        expect(result).to include('2. World')
        expect(result).to include('3. Test')
      end

      it 'limits to first 5 messages' do
        messages = (1..10).map { |i| "Message #{i}" }
        result = described_class.send(:format_recent_messages, messages)

        expect(result).to include('1. Message 1')
        expect(result).to include('5. Message 5')
        expect(result).not_to include('6. Message 6')
      end

      it 'returns placeholder for nil' do
        result = described_class.send(:format_recent_messages, nil)
        expect(result).to eq('(no recent messages)')
      end

      it 'returns placeholder for empty array' do
        result = described_class.send(:format_recent_messages, [])
        expect(result).to eq('(no recent messages)')
      end
    end

    describe '#default_gemini_result' do
      it 'returns unflagged result structure' do
        result = described_class.send(:default_gemini_result, false, 'Test reason')

        expect(result[:flagged]).to be false
        expect(result[:confidence]).to eq(0.0)
        expect(result[:reasoning]).to eq('Test reason')
        expect(result[:category]).to eq('none')
      end

      it 'can return flagged result' do
        result = described_class.send(:default_gemini_result, true, 'Flagged')
        expect(result[:flagged]).to be true
      end
    end

    describe '#default_claude_result' do
      it 'returns unconfirmed result structure' do
        result = described_class.send(:default_claude_result, false, 'Test reason')

        expect(result[:confirmed]).to be false
        expect(result[:confidence]).to eq(0.0)
        expect(result[:reasoning]).to eq('Test reason')
        expect(result[:category]).to eq('false_positive')
        expect(result[:severity]).to eq('low')
        expect(result[:recommended_action]).to eq('none')
      end
    end
  end

  describe 'integration scenarios' do
    let(:normal_check) do
      double('AbuseCheck',
        message_type: 'say',
        message_content: 'Hi everyone, nice to meet you!'
      )
    end

    let(:abusive_check) do
      double('AbuseCheck',
        message_type: 'say',
        message_content: 'I will find you OOC',
        abuse_category: 'threats',
        gemini_confidence: 0.9,
        gemini_reasoning: 'OOC threat detected',
        parsed_context: {
          'room_name' => 'Town Square',
          'recent_messages' => ['Previous hostile message']
        }
      )
    end

    context 'normal conversation flow' do
      before do
        allow(GamePrompts).to receive(:get).and_return('Test prompt')
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"flagged": false, "confidence": 0.05, "reasoning": "Normal greeting", "category": "none"}'
        })
      end

      it 'passes normal messages through gemini check' do
        result = described_class.gemini_check(normal_check)
        expect(result[:flagged]).to be false
      end
    end

    context 'escalation flow' do
      before do
        allow(GamePrompts).to receive(:get).and_return('Test prompt')
      end

      it 'flags suspicious content in first pass' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"flagged": true, "confidence": 0.9, "reasoning": "OOC threat", "category": "threats"}'
        })

        result = described_class.gemini_check(abusive_check)
        expect(result[:flagged]).to be true
        expect(result[:category]).to eq('threats')
      end

      it 'verifies flagged content in second pass' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"confirmed": true, "confidence": 0.95, "reasoning": "Confirmed OOC threat", "category": "threats", "severity": "high"}'
        })

        result = described_class.claude_verify(abusive_check)
        expect(result[:confirmed]).to be true
        expect(result[:severity]).to eq('high')
      end
    end
  end
end
