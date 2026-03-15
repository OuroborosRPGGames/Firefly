# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmCompressionService do
  include_context 'auto_gm_session_dataset'

  describe 'constants' do
    it 'has ACTIONS_PER_EVENT from config' do
      expect(described_class::ACTIONS_PER_EVENT).to eq(GameConfig::AutoGm::COMPRESSION[:actions_per_event])
    end

    it 'has EVENTS_PER_SCENE from config' do
      expect(described_class::EVENTS_PER_SCENE).to eq(GameConfig::AutoGm::COMPRESSION[:events_per_scene])
    end

    it 'has SCENES_PER_ACT from config' do
      expect(described_class::SCENES_PER_ACT).to eq(GameConfig::AutoGm::COMPRESSION[:scenes_per_act])
    end

    it 'has ACTS_PER_SESSION from config' do
      expect(described_class::ACTS_PER_SESSION).to eq(GameConfig::AutoGm::COMPRESSION[:acts_per_session])
    end
  end

  describe '.update' do
    before do
      allow(AutoGmSummary).to receive(:needs_abstraction?).and_return(false)
    end

    context 'when no summarization needed' do
      before do
        allow(auto_gm_actions_dataset).to receive(:count).and_return(2)
      end

      it 'returns empty array' do
        result = described_class.update(session)
        expect(result).to eq([])
      end
    end

    context 'when event summary needed' do
      let(:new_summary) { double('AutoGmSummary', id: 1) }

      before do
        # Setup for needs_event_summary? to return true
        allow(auto_gm_summaries_dataset).to receive(:where).and_return(
          double('Dataset', order: double('Dataset', first: nil))
        )
        allow(session).to receive(:auto_gm_actions).and_return(Array.new(10) { action })

        # Setup for create_event_summary to find actions
        allow(auto_gm_actions_dataset).to receive(:order).and_return(
          double('Dataset', limit: double('Dataset', all: [action]))
        )

        # Stub the private methods
        allow(described_class).to receive(:generate_summary).and_return('Generated summary')
        allow(described_class).to receive(:calculate_importance).and_return(0.6)
        allow(AutoGmSummary).to receive(:create_events_summary).and_return(new_summary)
      end

      it 'creates event summary when threshold reached' do
        expect(AutoGmSummary).to receive(:create_events_summary)
        described_class.update(session)
      end

      it 'returns created summaries' do
        result = described_class.update(session)
        expect(result).to include(new_summary)
      end
    end
  end

  describe '.get_relevant_summary' do
    context 'when best summary exists' do
      let(:summary) { double('AutoGmSummary', content: 'Summary content') }

      before do
        allow(AutoGmSummary).to receive(:best_for_context).and_return(summary)
      end

      it 'returns the summary content' do
        result = described_class.get_relevant_summary(session)
        expect(result).to eq('Summary content')
      end
    end

    context 'when no summary exists' do
      before do
        allow(AutoGmSummary).to receive(:best_for_context).and_return(nil)
        allow(auto_gm_actions_dataset).to receive(:where).and_return(
          double('Dataset', order: double('Dataset', limit: double('Dataset', all: [])))
        )
      end

      it 'returns default message' do
        result = described_class.get_relevant_summary(session)
        expect(result).to eq('The adventure has just begun.')
      end
    end

    context 'with recent actions but no summary' do
      let(:action) { double('AutoGmAction', emit_text: 'Something happened') }

      before do
        allow(AutoGmSummary).to receive(:best_for_context).and_return(nil)
        allow(auto_gm_actions_dataset).to receive(:where).and_return(
          double('Dataset', order: double('Dataset', limit: double('Dataset', all: [action])))
        )
      end

      it 'returns concatenated action texts' do
        result = described_class.get_relevant_summary(session)
        expect(result).to include('Something happened')
      end
    end
  end

  describe '.get_context_window' do
    let(:session_summary) { double('AutoGmSummary', content: 'Session overview') }
    let(:act_summary) { double('AutoGmSummary', content: 'Current act') }
    let(:scene_summary) { double('AutoGmSummary', content: 'Current scene') }
    let(:event_summary) { double('AutoGmSummary', content: 'Recent events') }
    let(:recent_action) { double('AutoGmAction', emit_text: 'Just now') }

    before do
      # Set up summary queries
      session_dataset = double('Dataset', first: session_summary)
      allow(auto_gm_summaries_dataset).to receive(:where).with(abstraction_level: AutoGmSummary::LEVEL_SESSION).and_return(
        double('Dataset', order: session_dataset)
      )

      act_dataset = double('Dataset', first: act_summary)
      allow(auto_gm_summaries_dataset).to receive(:where).with(abstraction_level: AutoGmSummary::LEVEL_ACT, abstracted: false).and_return(
        double('Dataset', order: act_dataset)
      )

      scene_dataset = double('Dataset', first: scene_summary)
      allow(auto_gm_summaries_dataset).to receive(:where).with(abstraction_level: AutoGmSummary::LEVEL_SCENE, abstracted: false).and_return(
        double('Dataset', order: scene_dataset)
      )

      event_dataset = double('Dataset', first: event_summary)
      allow(auto_gm_summaries_dataset).to receive(:where).with(abstraction_level: AutoGmSummary::LEVEL_EVENTS, abstracted: false).and_return(
        double('Dataset', order: event_dataset)
      )

      allow(auto_gm_actions_dataset).to receive(:where).and_return(
        double('Dataset', exclude: double('Dataset', order: double('Dataset', limit: double('Dataset', all: [recent_action]))))
      )
    end

    it 'includes session summary' do
      result = described_class.get_context_window(session)
      expect(result).to include('SESSION:')
      expect(result).to include('Session overview')
    end

    it 'includes act summary' do
      result = described_class.get_context_window(session)
      expect(result).to include('RECENT ACT:')
    end

    it 'includes scene summary' do
      result = described_class.get_context_window(session)
      expect(result).to include('CURRENT SCENE:')
    end

    it 'includes event summary' do
      result = described_class.get_context_window(session)
      expect(result).to include('RECENT EVENTS:')
    end

    it 'includes recent actions' do
      result = described_class.get_context_window(session)
      expect(result).to include('JUST NOW:')
    end

    context 'with max_tokens limit' do
      it 'truncates if content exceeds limit' do
        # max_tokens: 10 means max ~40 chars, but truncation adds '...'
        # The method truncates to max_tokens * 4 chars then adds '...'
        result = described_class.get_context_window(session, max_tokens: 10)
        # Result should be truncated - check that it ends with '...'
        # and is reasonably short (under 50 chars for 10 tokens)
        expect(result.length).to be <= 50
        expect(result).to end_with('...')
      end
    end
  end

  describe '.summarize_at_level' do
    let(:child_summary) { double('Summary', content: 'text', importance: 0.7, mark_abstracted!: true) }
    let(:new_summary) { double('Summary', id: 99) }

    before do
      # Setup for create_event_summary - needs actions
      allow(auto_gm_summaries_dataset).to receive(:where).and_return(
        double('Dataset', order: double('Dataset', first: nil), all: [])
      )
      allow(auto_gm_actions_dataset).to receive(:order).and_return(
        double('Dataset', limit: double('Dataset', all: [action]))
      )

      # Stub LLM summary generation
      allow(described_class).to receive(:generate_summary).and_return('Generated summary')
      allow(described_class).to receive(:generate_abstraction).and_return('Generated abstraction')
      allow(described_class).to receive(:calculate_importance).and_return(0.6)

      # Stub AutoGmSummary create methods
      allow(AutoGmSummary).to receive(:create_events_summary).and_return(new_summary)
      allow(AutoGmSummary).to receive(:create_scene_summary).and_return(new_summary)
      allow(AutoGmSummary).to receive(:create_act_summary).and_return(new_summary)
      allow(AutoGmSummary).to receive(:create_session_summary).and_return(new_summary)

      # Stub unabstracted_at_level for higher level summaries
      allow(AutoGmSummary).to receive(:unabstracted_at_level).and_return(
        double('Dataset', all: [child_summary])
      )
    end

    it 'creates events summary for level 1' do
      expect(AutoGmSummary).to receive(:create_events_summary)
      described_class.summarize_at_level(session, AutoGmSummary::LEVEL_EVENTS)
    end

    it 'creates scene summary for level 2' do
      expect(AutoGmSummary).to receive(:create_scene_summary)
      described_class.summarize_at_level(session, AutoGmSummary::LEVEL_SCENE)
    end

    it 'creates act summary for level 3' do
      expect(AutoGmSummary).to receive(:create_act_summary)
      described_class.summarize_at_level(session, AutoGmSummary::LEVEL_ACT)
    end

    it 'creates session summary for level 4' do
      expect(AutoGmSummary).to receive(:create_session_summary)
      described_class.summarize_at_level(session, AutoGmSummary::LEVEL_SESSION)
    end
  end

  describe 'private methods' do
    describe '#needs_event_summary?' do
      context 'when no previous summaries' do
        before do
          allow(auto_gm_summaries_dataset).to receive(:where).and_return(
            double('Dataset', order: double('Dataset', first: nil))
          )
          allow(session).to receive(:auto_gm_actions).and_return(Array.new(10) { action })
        end

        it 'returns true when action count >= threshold' do
          result = described_class.send(:needs_event_summary?, session)
          expect(result).to be true
        end
      end

      context 'with existing summary' do
        let(:last_summary) { double('Summary', created_at: Time.now - 300) }

        before do
          allow(auto_gm_summaries_dataset).to receive(:where).and_return(
            double('Dataset', order: double('Dataset', first: last_summary))
          )
          allow(auto_gm_actions_dataset).to receive(:where).and_return(
            double('Dataset', count: 10)
          )
        end

        it 'counts actions since last summary' do
          result = described_class.send(:needs_event_summary?, session)
          expect(result).to be true
        end
      end
    end

    describe '#calculate_importance' do
      it 'returns base importance for regular actions' do
        actions = [double('Action', action_type: 'emit')]
        result = described_class.send(:calculate_importance, actions)
        expect(result).to be >= 0.5
      end

      it 'increases importance for significant action types' do
        actions = [
          double('Action', action_type: 'reveal_secret'),
          double('Action', action_type: 'trigger_twist')
        ]
        result = described_class.send(:calculate_importance, actions)
        expect(result).to be > 0.5
      end

      it 'caps importance at 0.9' do
        actions = Array.new(10) { double('Action', action_type: 'reveal_secret') }
        result = described_class.send(:calculate_importance, actions)
        expect(result).to eq(0.9)
      end
    end
  end
end
