# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGmSummary do
  let(:room) { create(:room) }
  let(:session) { create(:auto_gm_session, starting_room: room) }

  describe 'constants' do
    it 'has abstraction levels' do
      expect(AutoGmSummary::LEVEL_EVENTS).to eq(1)
      expect(AutoGmSummary::LEVEL_SCENE).to eq(2)
      expect(AutoGmSummary::LEVEL_ACT).to eq(3)
      expect(AutoGmSummary::LEVEL_SESSION).to eq(4)
    end

    it 'has all levels in LEVELS' do
      expect(AutoGmSummary::LEVELS).to eq([1, 2, 3, 4])
    end

    it 'has level names' do
      expect(AutoGmSummary::LEVEL_NAMES[1]).to eq('events')
      expect(AutoGmSummary::LEVEL_NAMES[2]).to eq('scene')
      expect(AutoGmSummary::LEVEL_NAMES[3]).to eq('act')
      expect(AutoGmSummary::LEVEL_NAMES[4]).to eq('session')
    end

    it 'has abstraction thresholds' do
      expect(AutoGmSummary::ABSTRACTION_THRESHOLDS[1]).to eq(5)
      expect(AutoGmSummary::ABSTRACTION_THRESHOLDS[2]).to eq(3)
      expect(AutoGmSummary::ABSTRACTION_THRESHOLDS[3]).to eq(3)
    end
  end

  describe 'validations' do
    it 'requires session_id' do
      summary = AutoGmSummary.new(content: 'Test', abstraction_level: 1)
      expect(summary.valid?).to be false
      expect(summary.errors[:session_id]).not_to be_empty
    end

    it 'requires content' do
      summary = AutoGmSummary.new(session_id: session.id, abstraction_level: 1)
      expect(summary.valid?).to be false
      expect(summary.errors[:content]).not_to be_empty
    end

    it 'requires abstraction_level' do
      summary = AutoGmSummary.new(session_id: session.id, content: 'Test')
      # abstraction_level is set by before_create hook, but for validation alone:
      summary.abstraction_level = nil
      expect(summary.valid?).to be false
      expect(summary.errors[:abstraction_level]).not_to be_empty
    end

    it 'validates abstraction_level is in LEVELS' do
      summary = AutoGmSummary.new(session_id: session.id, content: 'Test', abstraction_level: 99)
      expect(summary.valid?).to be false
      expect(summary.errors[:abstraction_level]).not_to be_empty
    end

    it 'accepts valid summary' do
      summary = create(:auto_gm_summary, session: session)
      expect(summary.valid?).to be true
    end
  end

  describe 'before_create defaults' do
    it 'sets default importance when not provided' do
      summary = create(:auto_gm_summary, session: session, importance: nil)
      expect(summary.importance).to eq(0.5)
    end

    it 'sets default abstracted to false when not provided' do
      summary = create(:auto_gm_summary, session: session, abstracted: nil)
      expect(summary.abstracted).to be false
    end

    it 'uses default abstraction_level from factory' do
      summary = create(:auto_gm_summary, session: session)
      expect(summary.abstraction_level).to eq(AutoGmSummary::LEVEL_EVENTS)
    end
  end

  describe 'level checks' do
    describe '#events_level?' do
      it 'returns true for level 1' do
        summary = create(:auto_gm_summary, session: session, abstraction_level: 1)
        expect(summary.events_level?).to be true
      end

      it 'returns false for other levels' do
        summary = create(:auto_gm_summary, :scene_level, session: session)
        expect(summary.events_level?).to be false
      end
    end

    describe '#scene_level?' do
      it 'returns true for level 2' do
        summary = create(:auto_gm_summary, :scene_level, session: session)
        expect(summary.scene_level?).to be true
      end

      it 'returns false for other levels' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.scene_level?).to be false
      end
    end

    describe '#act_level?' do
      it 'returns true for level 3' do
        summary = create(:auto_gm_summary, :act_level, session: session)
        expect(summary.act_level?).to be true
      end

      it 'returns false for other levels' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.act_level?).to be false
      end
    end

    describe '#session_level?' do
      it 'returns true for level 4' do
        summary = create(:auto_gm_summary, :session_level, session: session)
        expect(summary.session_level?).to be true
      end

      it 'returns false for other levels' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.session_level?).to be false
      end
    end
  end

  describe '#level_name' do
    it 'returns events for level 1' do
      summary = create(:auto_gm_summary, session: session, abstraction_level: 1)
      expect(summary.level_name).to eq('events')
    end

    it 'returns scene for level 2' do
      summary = create(:auto_gm_summary, :scene_level, session: session)
      expect(summary.level_name).to eq('scene')
    end

    it 'returns act for level 3' do
      summary = create(:auto_gm_summary, :act_level, session: session)
      expect(summary.level_name).to eq('act')
    end

    it 'returns session for level 4' do
      summary = create(:auto_gm_summary, :session_level, session: session)
      expect(summary.level_name).to eq('session')
    end

    it 'returns unknown for invalid level' do
      summary = AutoGmSummary.new(abstraction_level: 99)
      expect(summary.level_name).to eq('unknown')
    end
  end

  describe 'abstraction state' do
    describe '#abstracted?' do
      it 'returns true when abstracted' do
        summary = create(:auto_gm_summary, :abstracted, session: session)
        expect(summary.abstracted?).to be true
      end

      it 'returns false when not abstracted' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.abstracted?).to be false
      end
    end

    describe '#can_abstract?' do
      it 'returns true when not abstracted and not at session level' do
        summary = create(:auto_gm_summary, session: session, abstraction_level: 1)
        expect(summary.can_abstract?).to be true
      end

      it 'returns false when abstracted' do
        summary = create(:auto_gm_summary, :abstracted, session: session)
        expect(summary.can_abstract?).to be false
      end

      it 'returns false when at session level' do
        summary = create(:auto_gm_summary, :session_level, session: session)
        expect(summary.can_abstract?).to be false
      end
    end

    describe '#mark_abstracted!' do
      it 'sets abstracted to true' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.abstracted).to be false

        summary.mark_abstracted!
        summary.refresh

        expect(summary.abstracted).to be true
      end
    end
  end

  describe 'embedding helpers' do
    describe '#has_embedding?' do
      it 'returns false when embedding_id is nil' do
        summary = create(:auto_gm_summary, session: session)
        expect(summary.has_embedding?).to be false
      end

      it 'returns true when embedding_id is set' do
        # The has_embedding? method just checks if embedding_id is not nil
        summary = create(:auto_gm_summary, session: session)
        summary.values[:embedding_id] = 999  # Fake ID for testing the method
        expect(summary.has_embedding?).to be true
      end
    end
  end

  describe '#preview' do
    it 'returns empty string for nil content' do
      summary = AutoGmSummary.new(content: nil)
      expect(summary.preview).to eq('')
    end

    it 'returns full content if under max length' do
      summary = create(:auto_gm_summary, session: session, content: 'Short content')
      expect(summary.preview(max_length: 100)).to eq('Short content')
    end

    it 'truncates content over max length' do
      long_content = 'x' * 150
      summary = create(:auto_gm_summary, session: session, content: long_content)
      preview = summary.preview(max_length: 100)

      expect(preview.length).to eq(100)
      expect(preview).to end_with('...')
    end
  end

  describe 'class methods' do
    describe '.create_events_summary' do
      it 'creates summary at events level' do
        summary = AutoGmSummary.create_events_summary(session, 'Event happened')

        expect(summary.abstraction_level).to eq(AutoGmSummary::LEVEL_EVENTS)
        expect(summary.content).to eq('Event happened')
        expect(summary.importance).to eq(0.5)
      end

      it 'accepts custom importance' do
        summary = AutoGmSummary.create_events_summary(session, 'Important event', importance: 0.8)
        expect(summary.importance).to eq(0.8)
      end
    end

    describe '.create_scene_summary' do
      it 'creates summary at scene level' do
        summary = AutoGmSummary.create_scene_summary(session, 'Scene completed')

        expect(summary.abstraction_level).to eq(AutoGmSummary::LEVEL_SCENE)
        expect(summary.content).to eq('Scene completed')
        expect(summary.importance).to eq(0.6)
      end
    end

    describe '.create_act_summary' do
      it 'creates summary at act level' do
        summary = AutoGmSummary.create_act_summary(session, 'Act completed')

        expect(summary.abstraction_level).to eq(AutoGmSummary::LEVEL_ACT)
        expect(summary.content).to eq('Act completed')
        expect(summary.importance).to eq(0.7)
      end
    end

    describe '.create_session_summary' do
      it 'creates summary at session level' do
        summary = AutoGmSummary.create_session_summary(session, 'Adventure completed')

        expect(summary.abstraction_level).to eq(AutoGmSummary::LEVEL_SESSION)
        expect(summary.content).to eq('Adventure completed')
        expect(summary.importance).to eq(0.9)
      end
    end

    describe '.unabstracted_at_level' do
      before do
        @unabstracted1 = create(:auto_gm_summary, session: session, abstraction_level: 1)
        @unabstracted2 = create(:auto_gm_summary, session: session, abstraction_level: 1)
        @abstracted = create(:auto_gm_summary, :abstracted, session: session, abstraction_level: 1)
        @other_level = create(:auto_gm_summary, :scene_level, session: session)
      end

      it 'returns unabstracted summaries at specified level' do
        results = AutoGmSummary.unabstracted_at_level(session, 1).all

        expect(results.map(&:id)).to include(@unabstracted1.id, @unabstracted2.id)
        expect(results.map(&:id)).not_to include(@abstracted.id)
        expect(results.map(&:id)).not_to include(@other_level.id)
      end

      it 'orders by created_at' do
        results = AutoGmSummary.unabstracted_at_level(session, 1).all

        expect(results.first.id).to eq(@unabstracted1.id)
        expect(results.last.id).to eq(@unabstracted2.id)
      end
    end

    describe '.needs_abstraction?' do
      it 'returns false when below threshold' do
        create(:auto_gm_summary, session: session, abstraction_level: 1)
        expect(AutoGmSummary.needs_abstraction?(session, 1)).to be false
      end

      it 'returns true when at threshold' do
        5.times { create(:auto_gm_summary, session: session, abstraction_level: 1) }
        expect(AutoGmSummary.needs_abstraction?(session, 1)).to be true
      end

      it 'returns false for level without threshold' do
        expect(AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_SESSION)).to be false
      end
    end

    describe '.best_for_context' do
      it 'returns highest level summary' do
        create(:auto_gm_summary, session: session, abstraction_level: 1)
        scene = create(:auto_gm_summary, :scene_level, session: session)
        act = create(:auto_gm_summary, :act_level, session: session)

        result = AutoGmSummary.best_for_context(session)
        expect(result.id).to eq(act.id)
      end

      it 'returns most recent at same level' do
        old = create(:auto_gm_summary, :scene_level, session: session)
        new = create(:auto_gm_summary, :scene_level, session: session)

        result = AutoGmSummary.best_for_context(session)
        expect(result.id).to eq(new.id)
      end

      it 'returns nil when no summaries' do
        expect(AutoGmSummary.best_for_context(session)).to be_nil
      end
    end

    describe '.by_level' do
      before do
        @events1 = create(:auto_gm_summary, session: session, abstraction_level: 1)
        @events2 = create(:auto_gm_summary, session: session, abstraction_level: 1)
        @scene = create(:auto_gm_summary, :scene_level, session: session)
      end

      it 'groups summaries by abstraction level' do
        result = AutoGmSummary.by_level(session)

        expect(result[1].count).to eq(2)
        expect(result[2].count).to eq(1)
      end

      it 'returns empty hash for session without summaries' do
        other_session = create(:auto_gm_session, starting_room: room)
        result = AutoGmSummary.by_level(other_session)
        expect(result).to eq({})
      end
    end

    describe '.needing_embeddings' do
      it 'returns summaries without embeddings' do
        needs_embedding = create(:auto_gm_summary, session: session)

        results = AutoGmSummary.needing_embeddings.all

        expect(results.map(&:id)).to include(needs_embedding.id)
      end

      it 'filters by embedding_id IS NULL' do
        # Test that the query filters correctly (FK constraint prevents easy integration test)
        expect(AutoGmSummary.needing_embeddings.sql).to include('embedding_id')
      end
    end
  end
end
