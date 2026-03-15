# frozen_string_literal: true

class NarrativeThreadEntity < Sequel::Model
  plugin :validation_helpers

  ROLES = %w[protagonist antagonist catalyst setting theme].freeze

  many_to_one :narrative_thread
  many_to_one :narrative_entity

  def validate
    super
    validates_presence [:narrative_thread_id, :narrative_entity_id]
    validates_includes ROLES, :role if role
  end
end
