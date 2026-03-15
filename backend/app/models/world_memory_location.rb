# frozen_string_literal: true

# Junction table linking WorldMemory to Rooms (locations)
class WorldMemoryLocation < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :world_memory
  many_to_one :room

  def validate
    super
    validates_presence [:world_memory_id, :room_id]
  end

  class << self
    # Get all unabstracted memories for a room at a given level in the location branch
    # @param room_id [Integer]
    # @param level [Integer]
    # @return [Sequel::Dataset]
    def unabstracted_memories_for_room(room_id, level)
      memory_ids = where(room_id: room_id).select(:world_memory_id)

      WorldMemory
        .where(id: memory_ids)
        .where(abstraction_level: level)
        .exclude(
          id: WorldMemoryAbstraction
                .where(branch_type: 'location', branch_reference_id: room_id)
                .select(:source_memory_id)
        )
        .order(:created_at)
    end
  end
end
