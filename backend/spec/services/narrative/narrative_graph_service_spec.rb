# frozen_string_literal: true

RSpec.describe NarrativeGraphService do
  describe '.age_available?' do
    it 'returns a boolean' do
      NarrativeGraphService.reset_cache!
      result = NarrativeGraphService.age_available?
      expect([true, false]).to include(result)
    end
  end

  describe '.find_clusters_relational' do
    context 'with connected entities' do
      let!(:entity_a) { create(:narrative_entity, name: 'Entity A') }
      let!(:entity_b) { create(:narrative_entity, name: 'Entity B') }
      let!(:entity_c) { create(:narrative_entity, name: 'Entity C') }
      let!(:entity_d) { create(:narrative_entity, name: 'Entity D') }

      before do
        create(:narrative_relationship, source_entity: entity_a, target_entity: entity_b)
        create(:narrative_relationship, source_entity: entity_b, target_entity: entity_c)
        create(:narrative_relationship, source_entity: entity_c, target_entity: entity_a)
      end

      it 'finds clusters of connected entities' do
        clusters = NarrativeGraphService.find_clusters_relational(min_size: 3)
        expect(clusters.length).to be >= 1
        cluster_ids = clusters.first.sort
        expect(cluster_ids).to include(entity_a.id, entity_b.id, entity_c.id)
      end

      it 'excludes clusters below min_size' do
        clusters = NarrativeGraphService.find_clusters_relational(min_size: 4)
        expect(clusters).to be_empty
      end

      it 'does not include disconnected entities' do
        clusters = NarrativeGraphService.find_clusters_relational(min_size: 3)
        all_ids = clusters.flatten
        expect(all_ids).not_to include(entity_d.id)
      end
    end

    context 'with two separate clusters' do
      let!(:a1) { create(:narrative_entity, name: 'Cluster1-A') }
      let!(:a2) { create(:narrative_entity, name: 'Cluster1-B') }
      let!(:a3) { create(:narrative_entity, name: 'Cluster1-C') }
      let!(:b1) { create(:narrative_entity, name: 'Cluster2-A') }
      let!(:b2) { create(:narrative_entity, name: 'Cluster2-B') }
      let!(:b3) { create(:narrative_entity, name: 'Cluster2-C') }

      before do
        create(:narrative_relationship, source_entity: a1, target_entity: a2)
        create(:narrative_relationship, source_entity: a2, target_entity: a3)
        create(:narrative_relationship, source_entity: a3, target_entity: a1)
        create(:narrative_relationship, source_entity: b1, target_entity: b2)
        create(:narrative_relationship, source_entity: b2, target_entity: b3)
        create(:narrative_relationship, source_entity: b3, target_entity: b1)
      end

      it 'identifies both clusters' do
        clusters = NarrativeGraphService.find_clusters_relational(min_size: 3)
        expect(clusters.length).to eq(2)
      end
    end
  end

  describe '.co_occurring_entities' do
    let!(:entity_a) { create(:narrative_entity) }
    let!(:entity_b) { create(:narrative_entity) }
    let!(:entity_c) { create(:narrative_entity) }
    let!(:memory) { create(:world_memory) }

    before do
      create(:narrative_entity_memory, narrative_entity: entity_a, world_memory: memory)
      create(:narrative_entity_memory, narrative_entity: entity_b, world_memory: memory)
    end

    it 'finds entities that share memories' do
      results = NarrativeGraphService.co_occurring_entities(entity_a.id)
      result_ids = results.map { |r| r[:entity_id] }
      expect(result_ids).to include(entity_b.id)
    end
  end
end
