# frozen_string_literal: true

class NarrativeEntity < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  ENTITY_TYPES = %w[character location faction item concept theme event].freeze

  one_to_many :narrative_entity_memories
  one_to_many :source_relationships, class: :NarrativeRelationship, key: :source_entity_id
  one_to_many :target_relationships, class: :NarrativeRelationship, key: :target_entity_id
  one_to_many :narrative_thread_entities
  many_to_one :merged_into, class: :NarrativeEntity, key: :merged_into_id

  dataset_module do
    def active
      where(is_active: true, merged_into_id: nil)
    end

    def of_type(type)
      where(entity_type: type)
    end

    def by_importance
      order(Sequel.desc(:importance))
    end

    def recently_active(days: 30)
      where { last_seen_at >= Time.now - (days * 86_400) }
    end
  end

  def validate
    super
    validates_presence [:name, :entity_type]
    validates_includes ENTITY_TYPES, :entity_type
  end

  def before_save
    super
    self.updated_at = Time.now
    self.last_seen_at ||= Time.now
  end

  # Resolve to the actual game object if canonical link exists
  # @return [Sequel::Model, nil]
  def canonical_object
    return nil unless canonical_type && canonical_id

    case canonical_type
    when 'Character'
      Character[canonical_id]
    when 'Room'
      Room[canonical_id]
    when 'Group'
      Group[canonical_id] if defined?(Group)
    when 'Item'
      Item[canonical_id]
    else
      nil
    end
  rescue StandardError => e
    warn "[NarrativeEntity] Failed to resolve canonical object for #{entity_type}##{canonical_id}: #{e.message}"
    nil
  end

  # All relationships (both directions), optionally filtered to current only
  # @param current_only [Boolean]
  # @return [Array<NarrativeRelationship>]
  def relationships(current_only: true)
    source = NarrativeRelationship.where(source_entity_id: id)
    target = NarrativeRelationship.where(target_entity_id: id)

    if current_only
      source = source.where(is_current: true)
      target = target.where(is_current: true)
    end

    (source.all + target.all).uniq(&:id)
  end

  # Threads this entity participates in
  # @return [Array<NarrativeThread>]
  def threads
    thread_ids = NarrativeThreadEntity.where(narrative_entity_id: id).select_map(:narrative_thread_id)
    NarrativeThread.where(id: thread_ids).all
  end

  # World memories this entity is linked to
  # @return [Array<WorldMemory>]
  def world_memories
    memory_ids = NarrativeEntityMemory.where(narrative_entity_id: id).select_map(:world_memory_id)
    WorldMemory.where(id: memory_ids).order(Sequel.desc(:memory_at)).all
  end

  # Increment mention count and update last_seen_at
  def record_mention!
    update(
      mention_count: mention_count + 1,
      last_seen_at: Time.now
    )
  end

  class << self
    # Find by canonical game object
    # @param type [String] e.g. 'Character'
    # @param id [Integer]
    # @return [NarrativeEntity, nil]
    def find_by_canonical(type, id)
      active.first(canonical_type: type, canonical_id: id)
    end

    # Find by name (case-insensitive)
    # @param name [String]
    # @return [NarrativeEntity, nil]
    def find_by_name(name)
      active.first(Sequel.ilike(:name, name))
    end

    # Find by alias (JSONB contains)
    # @param alias_name [String]
    # @return [NarrativeEntity, nil]
    def find_by_alias(alias_name)
      active.where(
        Sequel.lit("aliases @> ?::jsonb", [alias_name].to_json)
      ).first
    end

    # Search entities by name or alias
    # @param query [String]
    # @param limit [Integer]
    # @return [Array<NarrativeEntity>]
    def search(query, limit: 20)
      pattern = "%#{query}%"
      active
        .where(Sequel.ilike(:name, pattern))
        .or(Sequel.lit("aliases::text ILIKE ?", pattern))
        .order(Sequel.desc(:importance))
        .limit(limit)
        .all
    end
  end
end
