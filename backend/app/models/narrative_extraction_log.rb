# frozen_string_literal: true

class NarrativeExtractionLog < Sequel::Model
  plugin :validation_helpers

  TIERS = %w[batch comprehensive].freeze

  many_to_one :world_memory

  def validate
    super
    validates_presence [:world_memory_id, :extraction_tier]
    validates_includes TIERS, :extraction_tier
    validates_unique :world_memory_id
  end

  class << self
    # Check if a memory has already been extracted
    # @param memory_id [Integer]
    # @return [Boolean]
    def extracted?(memory_id)
      !where(world_memory_id: memory_id, success: true).empty?
    end
  end
end
