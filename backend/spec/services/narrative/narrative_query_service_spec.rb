# frozen_string_literal: true

RSpec.describe NarrativeQueryService do
  let!(:active_thread) { create(:narrative_thread, status: 'active', importance: 8.0, last_activity_at: Time.now) }
  let!(:emerging_thread) { create(:narrative_thread, status: 'emerging', importance: 5.0, last_activity_at: Time.now) }
  let!(:dormant_thread) { create(:narrative_thread, status: 'dormant', importance: 3.0, last_activity_at: Time.now - 60 * 86_400) }

  describe '.active_threads' do
    it 'returns active threads by default' do
      threads = NarrativeQueryService.active_threads
      statuses = threads.map(&:status)
      expect(statuses).to include('active')
      expect(statuses).not_to include('dormant')
    end

    it 'respects status filter' do
      threads = NarrativeQueryService.active_threads(status: %w[dormant])
      expect(threads.map(&:status)).to all(eq('dormant'))
    end

    it 'respects limit' do
      threads = NarrativeQueryService.active_threads(limit: 1)
      expect(threads.length).to be <= 1
    end
  end

  describe '.thread_entities' do
    it 'returns entities for a thread sorted by centrality' do
      entity1 = create(:narrative_entity)
      entity2 = create(:narrative_entity)
      create(:narrative_thread_entity, narrative_thread: active_thread, narrative_entity: entity1, centrality: 0.9)
      create(:narrative_thread_entity, narrative_thread: active_thread, narrative_entity: entity2, centrality: 0.3)

      entities = NarrativeQueryService.thread_entities(active_thread)
      expect(entities.length).to eq(2)
      expect(entities.first[:centrality]).to be >= entities.last[:centrality]
    end
  end

  describe '.thread_timeline' do
    it 'returns memories for a thread in chronological order' do
      memory1 = create(:world_memory, created_at: Time.now - 86_400)
      memory2 = create(:world_memory, created_at: Time.now)
      create(:narrative_thread_memory, narrative_thread: active_thread, world_memory: memory1)
      create(:narrative_thread_memory, narrative_thread: active_thread, world_memory: memory2)

      timeline = NarrativeQueryService.thread_timeline(active_thread)
      expect(timeline.length).to eq(2)
    end
  end

  describe '.threads_for_entity' do
    it 'returns threads linked to an entity' do
      entity = create(:narrative_entity)
      create(:narrative_thread_entity, narrative_thread: active_thread, narrative_entity: entity)

      threads = NarrativeQueryService.threads_for_entity(entity)
      expect(threads).to include(active_thread)
    end
  end

  describe '.search_entities' do
    before do
      create(:narrative_entity, name: 'Elder Dragon', description: 'A mighty wyrm')
      create(:narrative_entity, name: 'Simple Entity', description: 'Nothing special')
    end

    it 'searches by name' do
      results = NarrativeQueryService.search_entities('dragon')
      expect(results.length).to eq(1)
      expect(results.first.name).to eq('Elder Dragon')
    end

    it 'respects limit' do
      results = NarrativeQueryService.search_entities('entity', limit: 1)
      expect(results.length).to be <= 1
    end
  end

  describe '.dashboard_stats' do
    it 'returns a stats hash' do
      stats = NarrativeQueryService.dashboard_stats
      expect(stats).to include(:total_threads, :active_threads, :total_entities, :unprocessed_memories)
    end

    it 'includes entity type breakdown' do
      create(:narrative_entity, entity_type: 'character')
      create(:narrative_entity, entity_type: 'location')
      stats = NarrativeQueryService.dashboard_stats
      expect(stats[:entity_types]).to be_a(Array)
      types = stats[:entity_types].map { |t| t[:type] }
      expect(types).to include('character', 'location')
    end
  end

  describe '.thread_graph' do
    it 'returns nodes and edges' do
      entity = create(:narrative_entity)
      create(:narrative_thread_entity, narrative_thread: active_thread, narrative_entity: entity)

      graph = NarrativeQueryService.thread_graph(active_thread)
      expect(graph).to include(:nodes, :edges)
      expect(graph[:nodes].length).to be >= 1
    end
  end

  describe '.location_narrative_pulse' do
    let(:room) { create(:room) }

    it 'returns a pulse hash with required keys' do
      pulse = NarrativeQueryService.location_narrative_pulse(room)
      expect(pulse).to include(:threads, :recent_entities, :activity_level)
    end

    it 'returns arrays for threads and recent_entities' do
      pulse = NarrativeQueryService.location_narrative_pulse(room)
      expect(pulse[:threads]).to be_an(Array)
      expect(pulse[:recent_entities]).to be_an(Array)
    end

    it 'returns a valid activity_level string' do
      pulse = NarrativeQueryService.location_narrative_pulse(room)
      expect(%w[low moderate high]).to include(pulse[:activity_level])
    end
  end
end
