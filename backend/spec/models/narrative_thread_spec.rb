# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeThread, type: :model do
  describe 'validations' do
    let(:thread) { build(:narrative_thread) }

    it 'requires a name' do
      thread.name = nil
      expect(thread.valid?).to be false
    end

    it 'requires a status' do
      thread.status = nil
      expect(thread.valid?).to be false
    end

    it 'rejects unknown statuses' do
      thread.status = 'not_real'
      expect(thread.valid?).to be false
    end

    it 'accepts all configured statuses' do
      NarrativeThread::STATUSES.each do |status|
        thread.status = status
        expect(thread.valid?).to be true
      end
    end
  end

  describe 'dataset scopes' do
    describe '.active_threads' do
      let!(:emerging) { create(:narrative_thread, status: 'emerging') }
      let!(:active) { create(:narrative_thread, status: 'active') }
      let!(:climax) { create(:narrative_thread, status: 'climax') }
      let!(:resolved) { create(:narrative_thread, status: 'resolved') }

      it 'returns only active lifecycle statuses' do
        results = described_class.active_threads.all
        expect(results).to include(emerging, active, climax)
        expect(results).not_to include(resolved)
      end
    end

    describe '.by_importance' do
      let!(:low) { create(:narrative_thread, importance: 1.0) }
      let!(:high) { create(:narrative_thread, importance: 9.0) }

      it 'sorts by importance descending' do
        expect(described_class.by_importance.all.first.id).to eq(high.id)
        expect(described_class.by_importance.all.last.id).to eq(low.id)
      end
    end

    describe '.by_activity' do
      let!(:older) { create(:narrative_thread, last_activity_at: Time.now - 3600) }
      let!(:newer) { create(:narrative_thread, last_activity_at: Time.now) }

      it 'sorts by last_activity_at descending' do
        expect(described_class.by_activity.all.first.id).to eq(newer.id)
        expect(described_class.by_activity.all.last.id).to eq(older.id)
      end
    end

    describe '.with_status' do
      let!(:target) { create(:narrative_thread, status: 'dormant') }
      let!(:other) { create(:narrative_thread, status: 'active') }

      it 'filters to the provided status' do
        results = described_class.with_status('dormant').all
        expect(results).to include(target)
        expect(results).not_to include(other)
      end
    end
  end

  describe 'instance methods' do
    describe '#active?' do
      it 'treats emerging as active' do
        thread = create(:narrative_thread, status: 'emerging')
        expect(thread.active?).to be true
      end

      it 'treats climax as active' do
        thread = create(:narrative_thread, status: 'climax')
        expect(thread.active?).to be true
      end

      it 'treats dormant as inactive' do
        thread = create(:narrative_thread, status: 'dormant')
        expect(thread.active?).to be false
      end
    end

    describe '#entities' do
      it 'returns entities sorted by centrality descending' do
        thread = create(:narrative_thread)
        low = create(:narrative_entity)
        high = create(:narrative_entity)
        create(:narrative_thread_entity, narrative_thread: thread, narrative_entity: low, centrality: 0.2)
        create(:narrative_thread_entity, narrative_thread: thread, narrative_entity: high, centrality: 0.9)

        expect(thread.entities.map(&:id)).to eq([high.id, low.id])
      end

      it 'returns empty array when no linked entities' do
        thread = create(:narrative_thread)
        expect(thread.entities).to eq([])
      end
    end

    describe '#memories' do
      it 'returns memories ordered by memory_at' do
        thread = create(:narrative_thread)
        late = create(:world_memory, memory_at: Time.now)
        early = create(:world_memory, memory_at: Time.now - 3600)
        create(:narrative_thread_memory, narrative_thread: thread, world_memory: late)
        create(:narrative_thread_memory, narrative_thread: thread, world_memory: early)

        expect(thread.memories.map(&:id)).to eq([early.id, late.id])
      end

      it 'returns empty array when no linked memories' do
        thread = create(:narrative_thread)
        expect(thread.memories).to eq([])
      end
    end

    describe '#add_entity!' do
      it 'creates a thread entity and updates entity_count' do
        thread = create(:narrative_thread, entity_count: 0)
        entity = create(:narrative_entity)

        thread.add_entity!(entity, centrality: 0.7, role: 'protagonist')
        thread.reload

        expect(thread.entity_count).to eq(1)
        join = NarrativeThreadEntity.where(narrative_thread_id: thread.id, narrative_entity_id: entity.id).first
        expect(join).not_to be_nil
        expect(join.centrality).to eq(0.7)
        expect(join.role).to eq('protagonist')
      end

      it 'does not create duplicates for the same entity' do
        thread = create(:narrative_thread)
        entity = create(:narrative_entity)

        thread.add_entity!(entity)
        thread.add_entity!(entity)
        thread.reload

        count = NarrativeThreadEntity.where(narrative_thread_id: thread.id, narrative_entity_id: entity.id).count
        expect(count).to eq(1)
        expect(thread.entity_count).to eq(1)
      end
    end

    describe '#add_memory!' do
      it 'creates a thread memory and updates memory_count' do
        thread = create(:narrative_thread, memory_count: 0)
        memory = create(:world_memory)
        old_activity = Time.now - 7200
        thread.update(last_activity_at: old_activity)

        thread.add_memory!(memory, relevance: 0.8)
        thread.reload

        expect(thread.memory_count).to eq(1)
        expect(thread.last_activity_at).to be > old_activity
        join = NarrativeThreadMemory.where(narrative_thread_id: thread.id, world_memory_id: memory.id).first
        expect(join).not_to be_nil
        expect(join.relevance).to eq(0.8)
      end

      it 'does not create duplicates for the same memory' do
        thread = create(:narrative_thread)
        memory = create(:world_memory)

        thread.add_memory!(memory)
        thread.add_memory!(memory)
        thread.reload

        count = NarrativeThreadMemory.where(narrative_thread_id: thread.id, world_memory_id: memory.id).count
        expect(count).to eq(1)
        expect(thread.memory_count).to eq(1)
      end
    end

    describe '#entity_id_set' do
      it 'returns unique linked entity ids as a set-like collection' do
        thread = create(:narrative_thread)
        entity_a = create(:narrative_entity)
        entity_b = create(:narrative_entity)
        create(:narrative_thread_entity, narrative_thread: thread, narrative_entity: entity_a)
        create(:narrative_thread_entity, narrative_thread: thread, narrative_entity: entity_b)

        expect(thread.entity_id_set.to_a).to contain_exactly(entity_a.id, entity_b.id)
      end
    end
  end
end
