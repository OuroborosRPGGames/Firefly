# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutohelperService do
  describe 'constants' do
    it 'defines CONTEXT_WINDOW_SECONDS from GameConfig' do
      expect(described_class::CONTEXT_WINDOW_SECONDS).to be_a(Integer)
      expect(described_class::CONTEXT_WINDOW_SECONDS).to be > 0
    end

    it 'defines MAX_HELPFILE_MATCHES' do
      expect(described_class::MAX_HELPFILE_MATCHES).to eq(5)
    end

    it 'defines SIMILARITY_THRESHOLD' do
      expect(described_class::SIMILARITY_THRESHOLD).to eq(0.3)
    end

    it 'defines MAX_RECENT_LOGS' do
      expect(described_class::MAX_RECENT_LOGS).to eq(10)
    end

    it 'defines LLM_PROVIDER' do
      expect(described_class::LLM_PROVIDER).to eq('google_gemini')
    end

    it 'defines LLM_MODEL' do
      expect(described_class::LLM_MODEL).to eq('gemini-3-flash-preview')
    end

    it 'defines MAX_TOKENS from GameConfig' do
      expect(described_class::MAX_TOKENS).to be_a(Integer)
      expect(described_class::MAX_TOKENS).to be > 0
    end

    it 'defines TEMPERATURE from GameConfig' do
      expect(described_class::TEMPERATURE).to be_a(Float)
    end
  end

  describe 'class methods' do
    it 'defines assist' do
      expect(described_class).to respond_to(:assist)
    end

    it 'defines should_trigger?' do
      expect(described_class).to respond_to(:should_trigger?)
    end
  end

  describe '.assist signature' do
    it 'accepts keyword parameters' do
      method = described_class.method(:assist)
      params = method.parameters.map(&:last)
      expect(params).to include(:query)
      expect(params).to include(:character_instance)
    end

    it 'accepts optional suggestions parameter' do
      method = described_class.method(:assist)
      params = method.parameters.map(&:last)
      expect(params).to include(:suggestions)
    end
  end

  describe '.should_trigger? signature' do
    it 'accepts topic and has_matches parameters' do
      method = described_class.method(:should_trigger?)
      params = method.parameters.map(&:last)
      expect(params).to include(:topic)
      expect(params).to include(:has_matches)
    end
  end

  describe '.should_trigger?' do
    before do
      allow(GameSetting).to receive(:boolean).with('autohelper_enabled').and_return(true)
    end

    context 'when autohelper is disabled' do
      before { allow(GameSetting).to receive(:boolean).with('autohelper_enabled').and_return(false) }

      it 'returns false regardless of other conditions' do
        expect(described_class.should_trigger?('how do I fight?', has_matches: false)).to be false
      end
    end

    context 'when autohelper is enabled' do
      it 'returns true when topic ends with ?' do
        expect(described_class.should_trigger?('how do I fight?', has_matches: true)).to be true
      end

      it 'returns true when topic ends with multiple ?' do
        expect(described_class.should_trigger?('what is combat???', has_matches: true)).to be true
      end

      it 'returns true when no matches found' do
        expect(described_class.should_trigger?('gibberish', has_matches: false)).to be true
      end

      it 'returns false when topic has no question mark and matches exist' do
        expect(described_class.should_trigger?('fight', has_matches: true)).to be false
      end

      it 'handles nil topic gracefully' do
        expect(described_class.should_trigger?(nil, has_matches: true)).to be false
      end
    end
  end

  describe '.assist' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    before do
      # Mock LLM availability
      allow(described_class).to receive(:llm_available?).and_return(true)
    end

    context 'with nil or empty query' do
      it 'returns error for nil query' do
        result = described_class.assist(query: nil, character_instance: character_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No query')
      end

      it 'returns error for empty query' do
        result = described_class.assist(query: '   ', character_instance: character_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No query')
      end
    end

    context 'with nil character_instance' do
      it 'returns error' do
        result = described_class.assist(query: 'how do I fight?', character_instance: nil)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Character instance required')
      end
    end

    context 'when LLM is not available' do
      before { allow(described_class).to receive(:llm_available?).and_return(false) }

      it 'returns error' do
        result = described_class.assist(query: 'how do I fight?', character_instance: character_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('LLM not available')
      end
    end

    context 'with valid inputs' do
      before do
        # Mock helpfile search
        allow(Helpfile).to receive(:search_helpfiles).and_return([])

        # Mock prior context lookup
        allow(HelpRequestCache).to receive(:recent_for).and_return(nil)

        # Mock LLM client
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "To fight someone, use the fight command.", "doc_assessment": {"has_issue": false}}'
        })

        # Mock cache storage
        allow(HelpRequestCache).to receive(:store)
      end

      it 'returns success with response' do
        result = described_class.assist(query: 'how do I fight?', character_instance: character_instance)
        expect(result[:success]).to be true
        expect(result[:response]).to include('fight')
        expect(result[:error]).to be_nil
      end

      it 'strips trailing question marks from query' do
        expect(Helpfile).to receive(:search_helpfiles).with('how do I fight', anything).and_return([])
        described_class.assist(query: 'how do I fight??', character_instance: character_instance)
      end

      it 'caches the request on success' do
        expect(HelpRequestCache).to receive(:store).with(hash_including(
          character_instance_id: character_instance.id,
          query: 'how do I fight?'
        ))
        described_class.assist(query: 'how do I fight?', character_instance: character_instance)
      end

      it 'does not cache on failure' do
        allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'API error' })
        expect(HelpRequestCache).not_to receive(:store)
        described_class.assist(query: 'how do I fight?', character_instance: character_instance)
      end
    end

    context 'when LLM generation fails' do
      before do
        allow(Helpfile).to receive(:search_helpfiles).and_return([])
        allow(HelpRequestCache).to receive(:recent_for).and_return(nil)
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Rate limit exceeded'
        })
      end

      it 'returns error response' do
        result = described_class.assist(query: 'help me', character_instance: character_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Rate limit')
      end
    end

    context 'when LLM raises exception' do
      before do
        allow(Helpfile).to receive(:search_helpfiles).and_return([])
        allow(HelpRequestCache).to receive(:recent_for).and_return(nil)
        allow(LLM::Client).to receive(:generate).and_raise(StandardError.new('Connection failed'))
      end

      it 'returns error response' do
        result = described_class.assist(query: 'help me', character_instance: character_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('AI help unavailable')
      end
    end

    context 'with helpfile matches' do
      let(:mock_helpfile) do
        double('Helpfile',
          topic: 'fight',
          command_name: 'fight',
          summary: 'Start combat with another character',
          syntax: 'fight <target>',
          description: 'Full description here',
          aliases: ['attack', 'combat']
        )
      end

      before do
        allow(Helpfile).to receive(:search_helpfiles).and_return([
          { helpfile: mock_helpfile, similarity: 0.8 }
        ])
        allow(HelpRequestCache).to receive(:recent_for).and_return(nil)
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "Based on the fight command...", "doc_assessment": {"has_issue": false}}'
        })
        allow(HelpRequestCache).to receive(:store)
      end

      it 'includes matched topics in response sources' do
        result = described_class.assist(query: 'how to attack', character_instance: character_instance)
        expect(result[:sources]).to include('fight')
      end
    end

    context 'with prior context (follow-up question)' do
      before do
        allow(Helpfile).to receive(:search_helpfiles).and_return([])
        allow(HelpRequestCache).to receive(:recent_for).and_return({
          query: 'how do I fight?',
          response: 'Use the fight command',
          matched_topics: ['fight'],
          seconds_ago: 30
        })
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "As I mentioned...", "doc_assessment": {"has_issue": false}}'
        })
        allow(HelpRequestCache).to receive(:store)
      end

      it 'includes prior context in prompt' do
        expect(LLM::Client).to receive(:generate).with(hash_including(:prompt)) do |args|
          expect(args[:prompt]).to include('PREVIOUS QUESTION')
          expect(args[:prompt]).to include('how do I fight?')
          { success: true, text: '{"answer": "As I mentioned...", "doc_assessment": {"has_issue": false}}' }
        end
        described_class.assist(query: 'but how do I target someone', character_instance: character_instance)
      end
    end

    context 'with suggestions' do
      before do
        allow(Helpfile).to receive(:search_helpfiles).and_return([])
        allow(HelpRequestCache).to receive(:recent_for).and_return(nil)
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "Did you mean fight or flight?", "doc_assessment": {"has_issue": false}}'
        })
        allow(HelpRequestCache).to receive(:store)
      end

      it 'includes suggestions in prompt' do
        expect(LLM::Client).to receive(:generate).with(hash_including(:prompt)) do |args|
          expect(args[:prompt]).to include('SIMILAR COMMANDS')
          expect(args[:prompt]).to include('fight, flight')
          { success: true, text: '{"answer": "Did you mean fight or flight?", "doc_assessment": {"has_issue": false}}' }
        end
        described_class.assist(
          query: 'figt',
          character_instance: character_instance,
          suggestions: %w[fight flight]
        )
      end
    end
  end

  describe 'documentation ticket creation' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    before do
      allow(described_class).to receive(:llm_available?).and_return(true)
      allow(Helpfile).to receive(:search_helpfiles).and_return([])
      allow(HelpRequestCache).to receive(:recent_for).and_return(nil)
      allow(HelpRequestCache).to receive(:store)
      allow(GameSetting).to receive(:get).and_call_original
      allow(GameSetting).to receive(:get).with('autohelper_ticket_threshold').and_return('notable')
    end

    context 'when LLM flags a documentation issue above threshold' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "To fight, use the fight command.", "doc_assessment": {"has_issue": true, "issue_type": "incomplete", "severity": "critical", "topic": "combat", "description": "Combat helpfile missing damage threshold info."}}'
        })
      end

      it 'creates a documentation ticket' do
        expect {
          described_class.assist(query: 'how do damage thresholds work?', character_instance: character_instance)
        }.to change { Ticket.where(category: 'documentation').count }.by(1)
      end

      it 'sets system_generated to true' do
        described_class.assist(query: 'how do damage thresholds work?', character_instance: character_instance)
        ticket = Ticket.where(category: 'documentation').last
        expect(ticket.system_generated).to be true
      end

      it 'sets ticket subject with issue type prefix' do
        described_class.assist(query: 'how do damage thresholds work?', character_instance: character_instance)
        ticket = Ticket.where(category: 'documentation').last
        expect(ticket.subject).to eq('[incomplete] combat')
      end

      it 'stores player query in game_context' do
        described_class.assist(query: 'how do damage thresholds work?', character_instance: character_instance)
        ticket = Ticket.where(category: 'documentation').last
        expect(ticket.game_context).to eq('how do damage thresholds work?')
      end

      it 'still returns the player-facing answer' do
        result = described_class.assist(query: 'how do damage thresholds work?', character_instance: character_instance)
        expect(result[:success]).to be true
        expect(result[:response]).to eq('To fight, use the fight command.')
      end
    end

    context 'when severity is below threshold' do
      before do
        allow(GameSetting).to receive(:get).with('autohelper_ticket_threshold').and_return('notable')
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "Use the fight command.", "doc_assessment": {"has_issue": true, "issue_type": "incomplete", "severity": "minor", "topic": "combat", "description": "Could mention aliases."}}'
        })
      end

      it 'does not create a ticket' do
        expect {
          described_class.assist(query: 'how to fight?', character_instance: character_instance)
        }.not_to change { Ticket.where(category: 'documentation').count }
      end
    end

    context 'when LLM says no issue' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "Use the fight command.", "doc_assessment": {"has_issue": false}}'
        })
      end

      it 'does not create a ticket' do
        expect {
          described_class.assist(query: 'how to fight?', character_instance: character_instance)
        }.not_to change { Ticket.where(category: 'documentation').count }
      end
    end

    context 'when a duplicate open ticket exists' do
      before do
        Ticket.create(
          user_id: nil,
          category: 'documentation',
          system_generated: true,
          subject: '[incomplete] combat',
          content: 'Previous issue',
          status: 'open'
        )
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '{"answer": "Use the fight command.", "doc_assessment": {"has_issue": true, "issue_type": "incomplete", "severity": "critical", "topic": "combat", "description": "Still missing."}}'
        })
      end

      it 'does not create a duplicate ticket' do
        expect {
          described_class.assist(query: 'how to fight?', character_instance: character_instance)
        }.not_to change { Ticket.where(category: 'documentation').count }
      end
    end

    context 'when LLM returns JSON wrapped in code fences' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: "```json\n{\"answer\": \"Use fight.\", \"doc_assessment\": {\"has_issue\": false}}\n```"
        })
      end

      it 'strips code fences and parses correctly' do
        result = described_class.assist(query: 'how to fight?', character_instance: character_instance)
        expect(result[:success]).to be true
        expect(result[:response]).to eq('Use fight.')
      end
    end

    context 'when LLM returns malformed JSON' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'This is not JSON at all, just a plain text answer.'
        })
      end

      it 'falls back to plain text response' do
        result = described_class.assist(query: 'how to fight?', character_instance: character_instance)
        expect(result[:success]).to be true
        expect(result[:response]).to eq('This is not JSON at all, just a plain text answer.')
      end

      it 'does not create a ticket' do
        expect {
          described_class.assist(query: 'how to fight?', character_instance: character_instance)
        }.not_to change { Ticket.where(category: 'documentation').count }
      end
    end
  end
end
