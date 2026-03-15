# frozen_string_literal: true

# WorldMemoryNpc links WorldMemory records to NPC characters.
# This is parallel to WorldMemoryCharacter which tracks PC involvement.
#
# NPC characters are identified by having is_npc: true on their Character record.
#
# @example Add an NPC to a memory
#   memory.add_npc!(dragon_character, role: 'spawned')
#
# @example Find memories involving a specific NPC
#   WorldMemoryNpc.where(character_id: npc.id).map(&:world_memory)
#
class WorldMemoryNpc < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :world_memory
  many_to_one :character

  # Roles for NPC involvement in memories
  # - involved: NPC participated in the events
  # - spawned: NPC was spawned during this event (e.g., Auto-GM adventure)
  # - mentioned: NPC was mentioned but not directly present
  ROLES = %w[involved spawned mentioned].freeze

  def validate
    super
    validates_presence [:world_memory_id, :character_id]
    validates_includes ROLES, :role if role
  end

  class << self
    # Get all memory links for a specific NPC
    # @param character_id [Integer]
    # @return [Sequel::Dataset]
    def for_npc(character_id)
      where(character_id: character_id)
    end

    # Get all memory links for a specific memory
    # @param memory_id [Integer]
    # @return [Sequel::Dataset]
    def for_memory(memory_id)
      where(world_memory_id: memory_id)
    end

    # Get all unabstracted memories for an NPC at a given level
    # Used by branch abstraction logic
    # @param character_id [Integer]
    # @param level [Integer]
    # @return [Sequel::Dataset]
    def unabstracted_memories_for_npc(character_id, level)
      memory_ids = where(character_id: character_id).select(:world_memory_id)

      WorldMemory
        .where(id: memory_ids)
        .where(abstraction_level: level)
        .exclude(
          id: WorldMemoryAbstraction
                .where(branch_type: 'npc', branch_reference_id: character_id)
                .select(:source_memory_id)
        )
        .order(:created_at)
    end
  end
end
