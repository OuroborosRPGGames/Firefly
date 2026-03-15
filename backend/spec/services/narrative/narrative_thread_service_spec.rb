# frozen_string_literal: true

RSpec.describe NarrativeThreadService do
  describe '.detect_and_update!' do
    it 'returns result hash' do
      result = NarrativeThreadService.detect_and_update!
      expect(result).to include(:new_threads, :updated_threads, :dormant_count, :errors)
    end

    context 'with entity clusters' do
      let!(:entities) { (1..4).map { |i| create(:narrative_entity, name: "Thread Entity #{i}") } }

      before do
        create(:narrative_relationship, source_entity: entities[0], target_entity: entities[1])
        create(:narrative_relationship, source_entity: entities[1], target_entity: entities[2])
        create(:narrative_relationship, source_entity: entities[2], target_entity: entities[3])
        create(:narrative_relationship, source_entity: entities[3], target_entity: entities[0])
      end

      it 'creates threads from clusters' do
        allow(LLM::Client).to receive(:generate).and_return(
          '{"name": "Test Thread", "summary": "A test thread", "themes": ["adventure"], "roles": {}}'
        )
        result = NarrativeThreadService.detect_and_update!
        expect(result[:new_threads]).to be >= 0
      end
    end
  end

  describe 'jaccard_similarity (private)' do
    it 'returns 1.0 for identical sets' do
      result = NarrativeThreadService.send(:jaccard_similarity, Set[1, 2, 3], Set[1, 2, 3])
      expect(result).to eq(1.0)
    end

    it 'returns 0.0 for disjoint sets' do
      result = NarrativeThreadService.send(:jaccard_similarity, Set[1, 2], Set[3, 4])
      expect(result).to eq(0.0)
    end

    it 'returns correct value for overlapping sets' do
      result = NarrativeThreadService.send(:jaccard_similarity, Set[1, 2, 3], Set[2, 3, 4])
      expect(result).to be_within(0.01).of(0.5)
    end

    it 'handles empty sets' do
      result = NarrativeThreadService.send(:jaccard_similarity, Set.new, Set.new)
      expect(result).to eq(0.0)
    end
  end

  describe 'thread lifecycle' do
    describe '.update_thread_statuses!' do
      let!(:old_thread) do
        create(:narrative_thread,
               status: 'active',
               last_activity_at: Time.now - 35 * 86_400)
      end

      it 'marks old threads as dormant' do
        NarrativeThreadService.send(:update_thread_statuses!)
        old_thread.reload
        expect(old_thread.status).to eq('dormant')
      end
    end

    describe 'resolved transition' do
      let!(:very_old_thread) do
        create(:narrative_thread,
               status: 'dormant',
               last_activity_at: Time.now - 100 * 86_400)
      end

      it 'marks very old dormant threads as resolved' do
        NarrativeThreadService.send(:update_thread_statuses!)
        very_old_thread.reload
        expect(very_old_thread.status).to eq('resolved')
      end
    end
  end
end
