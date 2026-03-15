# frozen_string_literal: true

# WorldMemoryAbstraction represents a DAG relationship between world memories.
# Instead of a simple parent->child chain, memories can be abstracted into
# multiple parallel branches based on their tags (location, character, NPC, lore).
#
# This allows a single memory about "Bob fighting a dragon at the tavern" to be:
# - Abstracted into Tavern location branch (with 7 other tavern memories)
# - Abstracted into Bob character branch (with 7 other Bob memories)
# - Abstracted into Dragon NPC branch (with 7 other dragon memories)
#
# @example Check if a memory has been abstracted into a specific branch
#   memory.abstracted_into_branch?(:location, room.id)
#
# @example Get all abstraction records for a branch
#   WorldMemoryAbstraction.for_branch(:character, character.id)
#
class WorldMemoryAbstraction < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :source_memory, class: :WorldMemory, key: :source_memory_id
  many_to_one :target_memory, class: :WorldMemory, key: :target_memory_id

  # Valid branch types for memory abstraction
  BRANCH_TYPES = %w[location character npc lore global].freeze

  def validate
    super
    validates_presence [:source_memory_id, :target_memory_id, :branch_type]
    validates_includes BRANCH_TYPES, :branch_type
  end

  class << self
    # Get all abstraction records for a specific branch type and reference
    # @param branch_type [String, Symbol]
    # @param reference_id [Integer, nil]
    # @return [Sequel::Dataset]
    def for_branch(branch_type, reference_id = nil)
      ds = where(branch_type: branch_type.to_s)
      ds = ds.where(branch_reference_id: reference_id) if reference_id
      ds
    end

    # Get all sources that have been abstracted into a target memory
    # @param target_memory_id [Integer]
    # @return [Sequel::Dataset]
    def sources_for(target_memory_id)
      where(target_memory_id: target_memory_id)
    end

    # Get all targets a source memory has been abstracted into
    # @param source_memory_id [Integer]
    # @return [Sequel::Dataset]
    def targets_for(source_memory_id)
      where(source_memory_id: source_memory_id)
    end
  end
end
