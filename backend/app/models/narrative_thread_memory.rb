# frozen_string_literal: true

class NarrativeThreadMemory < Sequel::Model
  plugin :validation_helpers

  many_to_one :narrative_thread
  many_to_one :world_memory

  def validate
    super
    validates_presence [:narrative_thread_id, :world_memory_id]
  end
end
