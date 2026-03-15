# frozen_string_literal: true

# Junction table linking WorldMemory to Characters
class WorldMemoryCharacter < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :world_memory
  many_to_one :character

  ROLES = %w[participant observer mentioned].freeze

  def validate
    super
    validates_presence [:world_memory_id, :character_id]
    validates_includes ROLES, :role if role
  end

  class << self
    # Get all unabstracted memories for a character at a given level in the character branch
    # @param character_id [Integer]
    # @param level [Integer]
    # @return [Sequel::Dataset]
    def unabstracted_memories_for_character(character_id, level)
      memory_ids = where(character_id: character_id).select(:world_memory_id)

      WorldMemory
        .where(id: memory_ids)
        .where(abstraction_level: level)
        .exclude(
          id: WorldMemoryAbstraction
                .where(branch_type: 'character', branch_reference_id: character_id)
                .select(:source_memory_id)
        )
        .order(:created_at)
    end
  end
end
