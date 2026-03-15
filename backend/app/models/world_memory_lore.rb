# frozen_string_literal: true

# WorldMemoryLore links WorldMemory records to Helpfiles (lore topics).
# This enables tracking of which world events relate to which lore topics,
# allowing for branch-based abstraction of lore-related memories.
#
# @example Add a lore topic to a memory
#   memory.add_lore!(helpfile, reference_type: 'central')
#
# @example Find memories mentioning a specific lore topic
#   WorldMemoryLore.where(helpfile_id: helpfile.id).map(&:world_memory)
#
class WorldMemoryLore < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :world_memory
  many_to_one :helpfile

  # Reference types for lore connections
  # - mentioned: Lore topic was mentioned in the events
  # - central: Lore topic was central to the events
  # - background: Lore topic provides background context
  REFERENCE_TYPES = %w[mentioned central background].freeze

  def validate
    super
    validates_presence [:world_memory_id, :helpfile_id]
    validates_includes REFERENCE_TYPES, :reference_type if reference_type
  end

  class << self
    # Get all memory links for a specific helpfile
    # @param helpfile_id [Integer]
    # @return [Sequel::Dataset]
    def for_helpfile(helpfile_id)
      where(helpfile_id: helpfile_id)
    end

    # Get all memory links for a specific memory
    # @param memory_id [Integer]
    # @return [Sequel::Dataset]
    def for_memory(memory_id)
      where(world_memory_id: memory_id)
    end

    # Get all unabstracted memories for a lore topic at a given level
    # Used by branch abstraction logic
    # @param helpfile_id [Integer]
    # @param level [Integer]
    # @return [Sequel::Dataset]
    def unabstracted_memories_for_lore(helpfile_id, level)
      memory_ids = where(helpfile_id: helpfile_id).select(:world_memory_id)

      WorldMemory
        .where(id: memory_ids)
        .where(abstraction_level: level)
        .exclude(
          id: WorldMemoryAbstraction
                .where(branch_type: 'lore', branch_reference_id: helpfile_id)
                .select(:source_memory_id)
        )
        .order(:created_at)
    end
  end
end
