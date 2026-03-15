# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SemoteInterpreterService do
  let(:character) { create(:character, forename: 'Alice') }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, stance: 'standing') }
  let(:couch) { create(:place, room: room, name: 'leather couch', capacity: 3) }

  describe '.blocklisted?' do
    it 'blocks dangerous commands' do
      expect(described_class.blocklisted?('pay')).to be true
      expect(described_class.blocklisted?('delete')).to be true
      expect(described_class.blocklisted?('teleport')).to be true
    end

    it 'blocks combat commands' do
      expect(described_class.blocklisted?('attack')).to be true
      expect(described_class.blocklisted?('fight')).to be true
      expect(described_class.blocklisted?('kill')).to be true
      expect(described_class.blocklisted?('challenge')).to be true
    end

    it 'blocks theft commands' do
      expect(described_class.blocklisted?('steal')).to be true
      expect(described_class.blocklisted?('pickpocket')).to be true
      expect(described_class.blocklisted?('rob')).to be true
    end

    it 'allows safe commands' do
      expect(described_class.blocklisted?('sit')).to be false
      expect(described_class.blocklisted?('walk')).to be false
      expect(described_class.blocklisted?('give')).to be false
    end
  end

  describe '.build_context' do
    before { couch }

    it 'builds room context for LLM' do
      context = described_class.build_context(character_instance)

      expect(context[:character_name]).to eq('Alice')
      expect(context[:stance]).to eq('standing')
      expect(context[:furniture_list]).to include('leather couch')
    end
  end

  describe '.parse_llm_response' do
    it 'parses valid JSON array' do
      response = '[{"command": "sit", "target": "couch"}]'
      actions = described_class.parse_llm_response(response)

      expect(actions).to eq([{ command: 'sit', target: 'couch' }])
    end

    it 'returns empty array for invalid JSON' do
      expect(described_class.parse_llm_response('not json')).to eq([])
    end

    it 'returns empty array for non-array JSON' do
      expect(described_class.parse_llm_response('{"command": "sit"}')).to eq([])
    end

    it 'filters out blocklisted commands' do
      response = '[{"command": "sit", "target": "couch"}, {"command": "teleport", "target": "home"}]'
      actions = described_class.parse_llm_response(response)

      expect(actions.length).to eq(1)
      expect(actions.first[:command]).to eq('sit')
    end

    it 'handles markdown code fences' do
      response = "```json\n[{\"command\": \"sit\", \"target\": \"couch\"}]\n```"
      actions = described_class.parse_llm_response(response)

      expect(actions).to eq([{ command: 'sit', target: 'couch' }])
    end
  end

  describe '.interpret' do
    it 'returns empty actions for emotes with no mechanical implications' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[]'
      )

      result = described_class.interpret('smiles warmly', character_instance)

      expect(result[:actions]).to eq([])
    end

    it 'extracts sit action from emote' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "sit", "target": "leather couch"}]'
      )

      result = described_class.interpret('sits down on the leather couch', character_instance)

      expect(result[:actions].first[:command]).to eq('sit')
      expect(result[:actions].first[:target]).to eq('leather couch')
    end

    it 'returns error on LLM failure' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: false,
        error: 'API error'
      )

      result = described_class.interpret('does something', character_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('API error')
    end

    it 'logs interpretation to SemoteLog' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '[{"command": "sit", "target": "couch"}]'
      )

      expect {
        described_class.interpret('sits on the couch', character_instance)
      }.to change(SemoteLog, :count).by(1)
    end
  end

  describe '.disambiguate' do
    it 'returns selected option from LLM' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '{"choice": "leather couch"}'
      )

      result = described_class.disambiguate(
        'sits down on the couch',
        'sit',
        'couch',
        ['leather couch', 'wooden bench']
      )

      expect(result).to eq('leather couch')
    end

    it 'returns nil when choice is not in options' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: true,
        text: '{"choice": "invalid option"}'
      )

      result = described_class.disambiguate(
        'sits somewhere',
        'sit',
        'somewhere',
        ['couch', 'chair']
      )

      expect(result).to be_nil
    end

    it 'returns nil on LLM failure' do
      allow(LLM::TextGenerationService).to receive(:generate).and_return(
        success: false,
        error: 'API error'
      )

      result = described_class.disambiguate(
        'sits down',
        'sit',
        'chair',
        ['wooden chair', 'metal chair']
      )

      expect(result).to be_nil
    end
  end
end
