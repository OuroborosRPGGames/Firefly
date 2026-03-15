# frozen_string_literal: true

class NarrativeRelationship < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :source_entity, class: :NarrativeEntity, key: :source_entity_id
  many_to_one :target_entity, class: :NarrativeEntity, key: :target_entity_id

  dataset_module do
    def current
      where(is_current: true)
    end

    def of_type(type)
      where(relationship_type: type)
    end

    def strong(min_strength: 3.0)
      where { strength >= min_strength }
    end
  end

  def validate
    super
    validates_presence [:source_entity_id, :target_entity_id, :relationship_type]
  end

  def before_save
    super
    self.updated_at = Time.now
    self.last_observed_at ||= Time.now
  end

  # Strengthen this relationship (more evidence found)
  def strengthen!(amount: 0.5)
    update(
      evidence_count: evidence_count + 1,
      strength: [strength + amount, 10.0].min,
      last_observed_at: Time.now
    )
  end

  # Get the other entity from this relationship
  # @param entity_id [Integer]
  # @return [NarrativeEntity]
  def other_entity(entity_id)
    if source_entity_id == entity_id
      target_entity
    else
      source_entity
    end
  end

  class << self
    # Find existing relationship between two entities
    # @return [NarrativeRelationship, nil]
    def find_between(entity_a_id, entity_b_id, type: nil)
      ds = where(
        Sequel.|(
          { source_entity_id: entity_a_id, target_entity_id: entity_b_id },
          { source_entity_id: entity_b_id, target_entity_id: entity_a_id }
        )
      )
      ds = ds.where(relationship_type: type) if type
      ds.first
    end

    # All relationships involving an entity
    # @param entity_id [Integer]
    # @return [Array<NarrativeRelationship>]
    def involving(entity_id)
      current.where(
        Sequel.|(
          { source_entity_id: entity_id },
          { target_entity_id: entity_id }
        )
      ).all
    end
  end
end
