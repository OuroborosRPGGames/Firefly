# frozen_string_literal: true

class NarrativeEntityMemory < Sequel::Model
  plugin :validation_helpers

  ROLES = %w[central mentioned background].freeze

  many_to_one :narrative_entity
  many_to_one :world_memory

  dataset_module do
    def reputation_relevant
      where(reputation_relevant: true)
    end
  end

  def validate
    super
    validates_presence [:narrative_entity_id, :world_memory_id]
    validates_includes ROLES, :role if role
  end
end
