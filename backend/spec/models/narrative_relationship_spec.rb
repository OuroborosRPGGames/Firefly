# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NarrativeRelationship, type: :model do
  describe 'validations' do
    let(:relationship) { create(:narrative_relationship) }

    it 'requires source_entity_id' do
      relationship.source_entity_id = nil
      expect(relationship.valid?).to be false
    end

    it 'requires target_entity_id' do
      relationship.target_entity_id = nil
      expect(relationship.valid?).to be false
    end

    it 'requires relationship_type' do
      relationship.relationship_type = nil
      expect(relationship.valid?).to be false
    end
  end

  describe 'dataset scopes' do
    describe '.current' do
      let!(:current_rel) { create(:narrative_relationship, is_current: true) }
      let!(:old_rel) { create(:narrative_relationship, is_current: false) }

      it 'returns only current relationships' do
        results = described_class.current.all
        expect(results).to include(current_rel)
        expect(results).not_to include(old_rel)
      end
    end

    describe '.of_type' do
      let!(:ally) { create(:narrative_relationship, relationship_type: 'allied_with') }
      let!(:enemy) { create(:narrative_relationship, relationship_type: 'enemy_of') }

      it 'filters by relationship type' do
        results = described_class.of_type('allied_with').all
        expect(results).to include(ally)
        expect(results).not_to include(enemy)
      end
    end

    describe '.strong' do
      let!(:weak) { create(:narrative_relationship, strength: 2.9) }
      let!(:strong) { create(:narrative_relationship, strength: 3.0) }
      let!(:very_strong) { create(:narrative_relationship, strength: 6.0) }

      it 'uses default minimum strength of 3.0' do
        results = described_class.strong.all
        expect(results).to include(strong, very_strong)
        expect(results).not_to include(weak)
      end

      it 'supports custom minimum strength' do
        results = described_class.strong(min_strength: 5.0).all
        expect(results).to include(very_strong)
        expect(results).not_to include(weak, strong)
      end
    end
  end

  describe 'lifecycle behavior' do
    it 'sets last_observed_at on save when missing' do
      relationship = create(:narrative_relationship, last_observed_at: nil)
      expect(relationship.last_observed_at).not_to be_nil
    end
  end

  describe '#strengthen!' do
    it 'increments evidence_count and strength' do
      relationship = create(:narrative_relationship, strength: 1.0, evidence_count: 2)
      old_last_observed_at = relationship.last_observed_at

      relationship.strengthen!(amount: 0.5)
      relationship.reload

      expect(relationship.evidence_count).to eq(3)
      expect(relationship.strength).to eq(1.5)
      expect(relationship.last_observed_at).to be >= old_last_observed_at
    end

    it 'caps strength at 10.0' do
      relationship = create(:narrative_relationship, strength: 9.8, evidence_count: 1)
      relationship.strengthen!(amount: 1.0)
      expect(relationship.reload.strength).to eq(10.0)
    end
  end

  describe '#other_entity' do
    let(:source) { create(:narrative_entity) }
    let(:target) { create(:narrative_entity) }
    let(:relationship) { create(:narrative_relationship, source_entity: source, target_entity: target) }

    it 'returns target when source id is provided' do
      expect(relationship.other_entity(source.id)).to eq(target)
    end

    it 'returns source when target id is provided' do
      expect(relationship.other_entity(target.id)).to eq(source)
    end
  end

  describe '.find_between' do
    let(:entity_a) { create(:narrative_entity) }
    let(:entity_b) { create(:narrative_entity) }

    it 'finds relationships regardless of source/target ordering' do
      relationship = create(:narrative_relationship,
                            source_entity: entity_a,
                            target_entity: entity_b,
                            relationship_type: 'allied_with')

      expect(described_class.find_between(entity_a.id, entity_b.id)).to eq(relationship)
      expect(described_class.find_between(entity_b.id, entity_a.id)).to eq(relationship)
    end

    it 'applies optional type filtering' do
      create(:narrative_relationship, source_entity: entity_a, target_entity: entity_b, relationship_type: 'allied_with')
      enemy = create(:narrative_relationship, source_entity: entity_b, target_entity: entity_a, relationship_type: 'enemy_of')

      expect(described_class.find_between(entity_a.id, entity_b.id, type: 'enemy_of')).to eq(enemy)
      expect(described_class.find_between(entity_a.id, entity_b.id, type: 'rival_of')).to be_nil
    end
  end

  describe '.involving' do
    it 'returns only current relationships involving the entity in either role' do
      entity = create(:narrative_entity)
      as_source = create(:narrative_relationship, source_entity: entity, target_entity: create(:narrative_entity), is_current: true)
      as_target = create(:narrative_relationship, source_entity: create(:narrative_entity), target_entity: entity, is_current: true)
      archived = create(:narrative_relationship, source_entity: entity, target_entity: create(:narrative_entity), is_current: false)

      results = described_class.involving(entity.id)
      expect(results).to include(as_source, as_target)
      expect(results).not_to include(archived)
    end
  end
end
