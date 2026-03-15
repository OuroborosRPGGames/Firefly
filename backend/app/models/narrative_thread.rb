# frozen_string_literal: true

class NarrativeThread < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  status_enum :status, %w[emerging active climax dormant resolved]

  one_to_many :narrative_thread_entities
  one_to_many :narrative_thread_memories

  dataset_module do
    def active_threads
      where(status: %w[emerging active climax])
    end

    def by_importance
      order(Sequel.desc(:importance))
    end

    def by_activity
      order(Sequel.desc(:last_activity_at))
    end

    def with_status(status)
      where(status: status)
    end
  end

  def validate
    super
    validates_presence [:name, :status]
    validate_status_enum
  end

  def before_save
    super
    self.updated_at = Time.now
  end

  # Override: active means emerging, active, or climax
  def active?
    %w[emerging active climax].include?(status)
  end

  # Get entities in this thread, sorted by centrality
  # @return [Array<NarrativeEntity>]
  def entities
    entity_ids = narrative_thread_entities_dataset.order(Sequel.desc(:centrality)).select_map(:narrative_entity_id)
    return [] if entity_ids.empty?

    NarrativeEntity.where(id: entity_ids).all.sort_by { |e| entity_ids.index(e.id) }
  end

  # Get world memories linked to this thread, chronological
  # @return [Array<WorldMemory>]
  def memories
    memory_ids = narrative_thread_memories_dataset.select_map(:world_memory_id)
    return [] if memory_ids.empty?

    WorldMemory.where(id: memory_ids).order(:memory_at).all
  end

  # Add an entity to this thread
  # @param entity [NarrativeEntity]
  # @param centrality [Float]
  # @param role [String, nil]
  def add_entity!(entity, centrality: 0.0, role: nil)
    NarrativeThreadEntity.find_or_create(
      narrative_thread_id: id,
      narrative_entity_id: entity.id
    ) do |te|
      te.centrality = centrality
      te.role = role
    end
    update(entity_count: narrative_thread_entities_dataset.count)
  end

  # Add a memory to this thread
  # @param memory [WorldMemory]
  # @param relevance [Float]
  def add_memory!(memory, relevance: 0.5)
    NarrativeThreadMemory.find_or_create(
      narrative_thread_id: id,
      world_memory_id: memory.id
    ) do |tm|
      tm.relevance = relevance
    end
    update(
      memory_count: narrative_thread_memories_dataset.count,
      last_activity_at: Time.now
    )
  end

  # Entity IDs as a Set (for Jaccard comparison)
  # @return [Set<Integer>]
  def entity_id_set
    Set.new(narrative_thread_entities_dataset.select_map(:narrative_entity_id))
  end
end
