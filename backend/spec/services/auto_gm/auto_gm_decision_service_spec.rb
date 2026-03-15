# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmDecisionService do
  include_context 'auto_gm_session_dataset'

  describe 'constants' do
    it 'has GM_MODEL configuration' do
      expect(described_class::GM_MODEL[:provider]).to eq('anthropic')
      expect(described_class::GM_MODEL[:model]).to include('claude-sonnet')
    end

    it 'has ACTION_TYPES array' do
      expect(AutoGmAction::ACTION_TYPES).to include('emit')
      expect(AutoGmAction::ACTION_TYPES).to include('roll_request')
      expect(AutoGmAction::ACTION_TYPES).to include('move_characters')
      expect(AutoGmAction::ACTION_TYPES).to include('spawn_npc')
      expect(AutoGmAction::ACTION_TYPES).to include('resolve_session')
    end

    it 'uses GamePrompts for decision prompt' do
      # Verify the prompt path exists in GamePrompts
      expect(GamePrompts.exists?('auto_gm.decision')).to be true
    end
  end

  describe '.decide' do
    let(:valid_decision) do
      {
        'action_type' => 'emit',
        'reasoning' => 'Continuing the narrative',
        'emit_text' => 'The shadows grow longer...'
      }
    end

    before do
      allow(auto_gm_summaries_dataset).to receive(:order).and_return(
        double('Dataset', first: nil)
      )
    end

    context 'when LLM call succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: valid_decision.to_json,
          usage: { 'output_tokens' => 100 }
        })
      end

      it 'returns decision hash' do
        result = described_class.decide(session)

        expect(result).to be_a(Hash)
        expect(result[:action_type]).to eq('emit')
      end

      it 'includes params from decision' do
        result = described_class.decide(session)
        expect(result[:params]['emit_text']).to eq('The shadows grow longer...')
      end

      it 'includes reasoning' do
        result = described_class.decide(session)
        expect(result[:reasoning]).to eq('Continuing the narrative')
      end

      it 'includes thinking tokens' do
        result = described_class.decide(session)
        expect(result[:thinking_tokens]).to eq(100)
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: false })
      end

      it 'returns default emit action' do
        result = described_class.decide(session)

        expect(result[:action_type]).to eq('emit')
        expect(result[:params]['emit_text']).to eq('The adventure continues...')
      end

      it 'includes fallback reason in params' do
        result = described_class.decide(session)
        expect(result[:params]['fallback_reason']).to include('LLM call failed')
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'not valid json'
        })
      end

      it 'returns default emit action' do
        result = described_class.decide(session)
        expect(result[:action_type]).to eq('emit')
      end

      it 'includes parse error in reasoning' do
        result = described_class.decide(session)
        expect(result[:reasoning]).to include('JSON parse error')
      end
    end

    context 'when validation fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: { 'action_type' => 'invalid_type', 'reasoning' => 'test' }.to_json
        })
      end

      it 'returns default emit action' do
        result = described_class.decide(session)
        expect(result[:action_type]).to eq('emit')
      end
    end
  end

  describe '.quick_response' do
    let(:situation) { 'The characters successfully defeated the monster' }

    context 'when LLM call succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'The monster falls with a thunderous crash...'
        })
      end

      it 'returns emit action type' do
        result = described_class.quick_response(session, situation)
        expect(result[:action_type]).to eq('emit')
      end

      it 'returns narrative text in params' do
        result = described_class.quick_response(session, situation)
        expect(result[:params]['emit_text']).to eq('The monster falls with a thunderous crash...')
      end

      it 'includes truncated reasoning' do
        result = described_class.quick_response(session, situation)
        expect(result[:reasoning]).to include('GM response to:')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: false })
      end

      it 'returns default text' do
        result = described_class.quick_response(session, situation)
        expect(result[:params]['emit_text']).to eq('The adventure continues...')
      end
    end
  end

  describe '.should_act?' do
    context 'when session is running' do
      before do
        allow(session).to receive(:status).and_return('running')
        allow(session).to receive(:in_combat?).and_return(false)
      end

      context 'with no actions' do
        before do
          allow(session).to receive(:auto_gm_actions).and_return([])
        end

        it 'returns true' do
          expect(described_class.should_act?(session)).to be true
        end
      end

      context 'with recent action' do
        let(:recent_action) { double('Action', created_at: Time.now - 10) }

        before do
          allow(session).to receive(:auto_gm_actions).and_return([recent_action])
          allow(auto_gm_actions_dataset).to receive(:order).and_return(
            double('Dataset', first: recent_action)
          )
        end

        it 'returns false if less than 30 seconds since last action' do
          expect(described_class.should_act?(session)).to be false
        end
      end

      context 'with old action' do
        let(:old_action) { double('Action', created_at: Time.now - 60) }

        before do
          allow(session).to receive(:auto_gm_actions).and_return([old_action])
          allow(auto_gm_actions_dataset).to receive(:order).and_return(
            double('Dataset', first: old_action)
          )
        end

        it 'returns true if more than 30 seconds since last action' do
          expect(described_class.should_act?(session)).to be true
        end
      end
    end

    context 'when session is in combat' do
      before do
        allow(session).to receive(:status).and_return('running')
        allow(session).to receive(:in_combat?).and_return(true)
      end

      it 'returns false' do
        expect(described_class.should_act?(session)).to be false
      end
    end

    context 'when session is not running' do
      before do
        allow(session).to receive(:status).and_return('completed')
      end

      it 'returns false' do
        expect(described_class.should_act?(session)).to be false
      end
    end

    context 'when session is in climax' do
      before do
        allow(session).to receive(:status).and_return('climax')
        allow(session).to receive(:in_combat?).and_return(false)
        allow(session).to receive(:auto_gm_actions).and_return([])
      end

      it 'returns true' do
        expect(described_class.should_act?(session)).to be true
      end
    end
  end

  describe 'private methods' do
    describe '#build_decision_context' do
      before do
        allow(auto_gm_summaries_dataset).to receive(:order).and_return(
          double('Dataset', first: nil)
        )
        allow(session).to receive(:participant_instances).and_return([char_instance])
        allow(char_instance).to receive(:current_room).and_return(room)
        allow(char_instance).to receive(:online).and_return(true)
        allow(DisplayHelper).to receive(:character_display_name).and_return('Test Hero')
      end

      it 'includes recent_actions' do
        result = described_class.send(:build_decision_context, session)
        expect(result).to have_key(:recent_actions)
      end

      it 'includes recent_summary' do
        result = described_class.send(:build_decision_context, session)
        expect(result).to have_key(:recent_summary)
      end

      it 'includes world_state' do
        result = described_class.send(:build_decision_context, session)
        expect(result).to have_key(:world_state)
      end

      it 'includes participant_states' do
        result = described_class.send(:build_decision_context, session)
        expect(result).to have_key(:participant_states)
      end
    end

    describe '#validate_decision' do
      it 'raises for missing action_type' do
        expect {
          described_class.send(:validate_decision, { 'reasoning' => 'test' })
        }.to raise_error(/Missing action_type/)
      end

      it 'raises for invalid action_type' do
        expect {
          described_class.send(:validate_decision, { 'action_type' => 'invalid', 'reasoning' => 'test' })
        }.to raise_error(/Invalid action_type/)
      end

      it 'raises for missing reasoning' do
        expect {
          described_class.send(:validate_decision, { 'action_type' => 'emit' })
        }.to raise_error(/Missing reasoning/)
      end

      it 'passes for valid decision' do
        expect {
          described_class.send(:validate_decision, {
            'action_type' => 'emit',
            'reasoning' => 'test',
            'emit_text' => 'The story continues...'
          })
        }.not_to raise_error
      end

      it 'raises for missing required action field' do
        expect {
          described_class.send(:validate_decision, { 'action_type' => 'emit', 'reasoning' => 'test' })
        }.to raise_error(/Missing required field for emit: emit_text/)
      end
    end

    describe '#format_stage_info' do
      let(:stages) do
        [
          { 'name' => 'Act 1', 'description' => 'Beginning', 'is_climax' => false },
          { 'name' => 'Act 2', 'description' => 'Middle', 'is_climax' => false },
          { 'name' => 'Climax', 'description' => 'Final battle', 'is_climax' => true }
        ]
      end

      it 'marks current stage with arrow' do
        result = described_class.send(:format_stage_info, stages, 0)
        expect(result).to include('>>>')
      end

      it 'marks climax stage' do
        result = described_class.send(:format_stage_info, stages, 2)
        expect(result).to include('[CLIMAX]')
      end
    end

    describe '#format_recent_actions' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_recent_actions, [])
        expect(result).to eq('No recent actions')
      end

      it 'returns default message for nil' do
        result = described_class.send(:format_recent_actions, nil)
        expect(result).to eq('No recent actions')
      end

      it 'formats action info' do
        actions = [{ type: 'emit', text: 'Something happened', status: 'completed' }]
        result = described_class.send(:format_recent_actions, actions)
        expect(result).to include('emit')
        expect(result).to include('Something happened')
      end
    end

    describe '#format_participants' do
      it 'returns default message for empty array' do
        result = described_class.send(:format_participants, [])
        expect(result).to eq('No participants')
      end

      it 'formats participant info' do
        participants = [{ name: 'Hero', online: true, room: 'Tavern' }]
        result = described_class.send(:format_participants, participants)
        expect(result).to include('Hero')
        expect(result).to include('online')
        expect(result).to include('Tavern')
      end

      it 'shows offline status' do
        participants = [{ name: 'Hero', online: false, room: 'Tavern' }]
        result = described_class.send(:format_participants, participants)
        expect(result).to include('offline')
      end
    end
  end
end
