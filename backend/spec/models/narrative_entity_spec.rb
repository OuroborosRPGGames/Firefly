# frozen_string_literal: true

RSpec.describe NarrativeEntity, type: :model do
  describe 'validations' do
    let(:entity) { build(:narrative_entity) }

    it 'requires a name' do
      entity.name = nil
      expect(entity.valid?).to be false
    end

    it 'requires an entity_type' do
      entity.entity_type = nil
      expect(entity.valid?).to be false
    end

    it 'validates entity_type is in allowed list' do
      entity.entity_type = 'invalid_type'
      expect(entity.valid?).to be false
    end

    it 'allows valid entity types' do
      NarrativeEntity::ENTITY_TYPES.each do |type|
        entity.entity_type = type
        expect(entity.valid?).to be true
      end
    end
  end

  describe '#ENTITY_TYPES' do
    it 'includes expected types' do
      expect(NarrativeEntity::ENTITY_TYPES).to include(
        'character', 'location', 'faction', 'item', 'concept', 'theme', 'event'
      )
    end
  end

  describe 'associations' do
    it 'has many narrative_entity_memories' do
      entity = create(:narrative_entity)
      memory = create(:world_memory)
      create(:narrative_entity_memory, narrative_entity: entity, world_memory: memory)
      expect(entity.narrative_entity_memories.count).to eq(1)
    end

    it 'has many source_relationships' do
      entity1 = create(:narrative_entity)
      entity2 = create(:narrative_entity)
      create(:narrative_relationship, source_entity: entity1, target_entity: entity2)
      expect(entity1.source_relationships.count).to eq(1)
    end

    it 'has many target_relationships' do
      entity1 = create(:narrative_entity)
      entity2 = create(:narrative_entity)
      create(:narrative_relationship, source_entity: entity1, target_entity: entity2)
      expect(entity2.target_relationships.count).to eq(1)
    end

    it 'has many narrative_thread_entities' do
      entity = create(:narrative_entity)
      thread = create(:narrative_thread)
      create(:narrative_thread_entity, narrative_entity: entity, narrative_thread: thread)
      expect(entity.narrative_thread_entities.count).to eq(1)
    end
  end

  describe 'dataset modules' do
    let!(:active_entity) { create(:narrative_entity, is_active: true) }
    let!(:inactive_entity) { create(:narrative_entity, is_active: false) }

    describe '.active' do
      it 'returns only active entities' do
        active = NarrativeEntity.active.all
        expect(active).to include(active_entity)
        expect(active).not_to include(inactive_entity)
      end
    end

    describe '.of_type' do
      let!(:character) { create(:narrative_entity, entity_type: 'character') }
      let!(:location) { create(:narrative_entity, entity_type: 'location') }

      it 'filters by entity type' do
        characters = NarrativeEntity.of_type('character').all
        expect(characters).to include(character)
        expect(characters).not_to include(location)
      end
    end

    describe '.by_importance' do
      let!(:important) { create(:narrative_entity, importance: 9.0) }
      let!(:unimportant) { create(:narrative_entity, importance: 2.0) }

      it 'orders by importance descending' do
        entities = NarrativeEntity.by_importance.all
        expect(entities.first.importance).to be > entities.last.importance
      end
    end

    describe '.recently_active' do
      let!(:recent) { create(:narrative_entity, last_seen_at: Time.now - 10 * 86_400) }
      let!(:old) { create(:narrative_entity, last_seen_at: Time.now - 40 * 86_400) }

      it 'returns entities seen within specified days' do
        entities = NarrativeEntity.recently_active(days: 30).all
        expect(entities).to include(recent)
        expect(entities).not_to include(old)
      end
    end
  end

  describe 'instance methods' do
    let(:entity) { create(:narrative_entity) }

    describe '#record_mention!' do
      it 'increments mention count' do
        expect { entity.record_mention! }.to change { entity.reload.mention_count }.by(1)
      end

      it 'updates last_seen_at' do
        old_time = Time.now - 1000
        entity.update(last_seen_at: old_time)
        entity.record_mention!
        expect(entity.reload.last_seen_at).to be > old_time
      end
    end

    describe '#relationships' do
      it 'returns relationships in both directions' do
        other1 = create(:narrative_entity)
        other2 = create(:narrative_entity)
        create(:narrative_relationship, source_entity: entity, target_entity: other1)
        create(:narrative_relationship, source_entity: other2, target_entity: entity)
        expect(entity.relationships.count).to eq(2)
      end

      it 'filters to current only by default' do
        other = create(:narrative_entity)
        create(:narrative_relationship, source_entity: entity, target_entity: other, is_current: true)
        create(:narrative_relationship, source_entity: entity, target_entity: other,
               relationship_type: 'enemy_of', is_current: false)
        expect(entity.relationships(current_only: true).count).to eq(1)
      end
    end
  end

  describe 'aliases field' do
    let(:entity) { create(:narrative_entity, aliases: ['alias1', 'alias2']) }

    it 'stores JSONB array' do
      expect(entity.aliases).to eq(['alias1', 'alias2'])
    end

    it 'defaults to empty array' do
      fresh = create(:narrative_entity)
      expect(fresh.aliases).to eq([])
    end
  end

  describe 'instance methods' do
    describe '#canonical_object' do
      it 'returns nil when no canonical link' do
        entity = create(:narrative_entity, canonical_type: nil, canonical_id: nil)
        expect(entity.canonical_object).to be_nil
      end

      it 'resolves Character canonical type' do
        character = create(:character)
        entity = create(:narrative_entity, canonical_type: 'Character', canonical_id: character.id)
        expect(entity.canonical_object).to eq(character)
      end

      it 'resolves Room canonical type' do
        room = create(:room)
        entity = create(:narrative_entity, canonical_type: 'Room', canonical_id: room.id)
        expect(entity.canonical_object).to eq(room)
      end

      it 'returns nil for unknown canonical type' do
        entity = create(:narrative_entity, canonical_type: 'Unknown', canonical_id: 999)
        expect(entity.canonical_object).to be_nil
      end

      it 'handles missing canonical object gracefully' do
        entity = create(:narrative_entity, canonical_type: 'Character', canonical_id: -1)
        expect(entity.canonical_object).to be_nil
      end
    end

    describe '#threads' do
      it 'returns associated narrative threads' do
        entity = create(:narrative_entity)
        thread = create(:narrative_thread)
        create(:narrative_thread_entity, narrative_entity: entity, narrative_thread: thread)

        expect(entity.threads).to include(thread)
      end

      it 'returns empty when no threads' do
        entity = create(:narrative_entity)
        expect(entity.threads).to be_empty
      end
    end

    describe '#world_memories' do
      it 'returns associated world memories' do
        entity = create(:narrative_entity)
        memory = create(:world_memory)
        create(:narrative_entity_memory, narrative_entity: entity, world_memory: memory)

        expect(entity.world_memories).to include(memory)
      end

      it 'returns empty when no memories' do
        entity = create(:narrative_entity)
        expect(entity.world_memories).to be_empty
      end
    end
  end

  describe 'class methods' do
    describe '.find_by_name' do
      it 'finds entity by case-insensitive name' do
        entity = create(:narrative_entity, name: 'Elder Dragon')
        found = NarrativeEntity.find_by_name('elder dragon')
        expect(found).to eq(entity)
      end

      it 'returns nil for non-existent name' do
        expect(NarrativeEntity.find_by_name('Nobody Here')).to be_nil
      end
    end

    describe '.find_by_canonical' do
      it 'finds entity by canonical type and id' do
        character = create(:character)
        entity = create(:narrative_entity, canonical_type: 'Character', canonical_id: character.id, is_active: true)
        expect(NarrativeEntity.find_by_canonical('Character', character.id)).to eq(entity)
      end

      it 'returns nil for non-existent canonical' do
        expect(NarrativeEntity.find_by_canonical('Character', -1)).to be_nil
      end

      it 'excludes inactive entities' do
        character = create(:character)
        create(:narrative_entity, canonical_type: 'Character', canonical_id: character.id, is_active: false)
        expect(NarrativeEntity.find_by_canonical('Character', character.id)).to be_nil
      end
    end

    describe '.find_by_alias' do
      it 'finds entity by alias' do
        entity = create(:narrative_entity, aliases: ['The Dragon', 'Ignathor'])
        found = NarrativeEntity.find_by_alias('The Dragon')
        expect(found).to eq(entity)
      end

      it 'returns nil for non-matching alias' do
        create(:narrative_entity, aliases: ['Known Alias'])
        expect(NarrativeEntity.find_by_alias('Unknown')).to be_nil
      end
    end

    describe '.search' do
      it 'searches name and description' do
        create(:narrative_entity, name: 'Elder Dragon', description: 'A mighty wyrm')
        create(:narrative_entity, name: 'Simple Entity')
        results = NarrativeEntity.search('dragon')
        expect(results.count).to eq(1)
      end

      it 'orders results by importance' do
        create(:narrative_entity, name: 'Dragon Minor', importance: 2.0)
        create(:narrative_entity, name: 'Dragon Major', importance: 9.0)
        results = NarrativeEntity.search('Dragon')
        expect(results.first.importance).to be > results.last.importance
      end

      it 'respects limit parameter' do
        3.times { |i| create(:narrative_entity, name: "Dragon #{i}") }
        results = NarrativeEntity.search('Dragon', limit: 2)
        expect(results.length).to eq(2)
      end
    end
  end
end
