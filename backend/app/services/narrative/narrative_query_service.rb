# frozen_string_literal: true

# NarrativeQueryService provides read-only query access to narrative intelligence data.
# Used by staff dashboards, Auto-GM context, and NPC awareness.
module NarrativeQueryService
  class << self
    # Get active threads, optionally filtered by location
    # @param location [Room, nil] filter threads by location proximity
    # @param status [Array<String>] thread statuses to include
    # @param limit [Integer]
    # @return [Array<NarrativeThread>]
    def active_threads(location: nil, status: %w[emerging active climax], limit: 10)
      ds = NarrativeThread.where(status: status).by_importance

      if location
        # Filter to threads with entities linked to memories near this location
        location_memory_ids = WorldMemory.for_location(location).select(:id) rescue nil
        if location_memory_ids
          thread_ids = NarrativeThreadMemory.where(world_memory_id: location_memory_ids)
                                            .select(:narrative_thread_id)
                                            .distinct
          ds = ds.where(id: thread_ids)
        end
      end

      ds.limit(limit).all
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching active threads: #{e.message}"
      []
    end

    # Get entities for a thread, sorted by centrality
    # @param thread [NarrativeThread]
    # @return [Array<Hash>] { entity:, centrality:, role: }
    def thread_entities(thread)
      return [] unless thread

      thread.narrative_thread_entities_dataset
            .order(Sequel.desc(:centrality))
            .all
            .map do |te|
              entity = NarrativeEntity[te.narrative_entity_id]
              next unless entity

              { entity: entity, centrality: te.centrality, role: te.role }
            end
            .compact
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching thread entities: #{e.message}"
      []
    end

    # Get thread timeline (memories in chronological order)
    # @param thread [NarrativeThread]
    # @return [Array<WorldMemory>]
    def thread_timeline(thread)
      return [] unless thread

      thread.memories
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching thread timeline: #{e.message}"
      []
    end

    # Get threads involving a specific entity
    # @param entity [NarrativeEntity]
    # @return [Array<NarrativeThread>]
    def threads_for_entity(entity)
      entity.threads
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching threads for entity: #{e.message}"
      []
    end

    # Get graph data for thread visualization
    # @param thread [NarrativeThread]
    # @return [Hash] { nodes: [], edges: [] }
    def thread_graph(thread)
      return { nodes: [], edges: [] } unless thread

      entities = thread_entities(thread)
      entity_ids = entities.map { |e| e[:entity].id }

      nodes = entities.map do |e|
        {
          id: e[:entity].id,
          name: e[:entity].name,
          type: e[:entity].entity_type,
          centrality: e[:centrality],
          role: e[:role],
          importance: e[:entity].importance
        }
      end

      relationships = NarrativeRelationship.current.where(
        Sequel.|(
          { source_entity_id: entity_ids, target_entity_id: entity_ids }
        )
      ).all

      edges = relationships.map do |r|
        {
          id: r.id,
          source: r.source_entity_id,
          target: r.target_entity_id,
          type: r.relationship_type,
          strength: r.strength,
          context: r.context
        }
      end

      { nodes: nodes, edges: edges }
    rescue StandardError => e
      warn "[NarrativeQuery] Error building thread graph: #{e.message}"
      { nodes: [], edges: [] }
    end

    # Search entities by name
    # @param query [String]
    # @param limit [Integer]
    # @return [Array<NarrativeEntity>]
    def search_entities(query, limit: 20)
      return [] if query.nil? || query.strip.empty?

      NarrativeEntity.search(query, limit: limit)
    rescue StandardError => e
      warn "[NarrativeQuery] Error searching entities: #{e.message}"
      []
    end

    # Get narrative pulse for a location (summary of narrative activity)
    # @param location [Room]
    # @return [Hash] { threads:, recent_entities:, activity_level: }
    def location_narrative_pulse(location)
      threads = active_threads(location: location, limit: 5)

      # Find entities mentioned in recent memories for this location
      location_memory_ids = WorldMemory.for_location(location)
                                       .where { created_at >= Time.now - (7 * 86_400) }
                                       .select(:id) rescue []
      entity_ids = NarrativeEntityMemory.where(world_memory_id: location_memory_ids)
                                        .distinct(:narrative_entity_id)
                                        .select_map(:narrative_entity_id)
      recent_entities = NarrativeEntity.where(id: entity_ids).by_importance.limit(10).all

      activity_level = if threads.size >= 3 then 'high'
                       elsif threads.size >= 1 then 'moderate'
                       else 'low'
                       end

      { threads: threads, recent_entities: recent_entities, activity_level: activity_level }
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching location pulse: #{e.message}"
      { threads: [], recent_entities: [], activity_level: 'low' }
    end

    # ========================================
    # Dashboard Stats
    # ========================================

    # Get summary statistics for admin dashboard
    # @return [Hash]
    def dashboard_stats
      {
        total_threads: NarrativeThread.count,
        active_threads: NarrativeThread.active_threads.count,
        total_entities: NarrativeEntity.active.count,
        total_relationships: NarrativeRelationship.current.count,
        unprocessed_memories: unprocessed_memory_count,
        entity_types: NarrativeEntity.active.group_and_count(:entity_type).order(Sequel.desc(:count)).all
                        .map { |r| { type: r[:entity_type], count: r[:count] } }
      }
    rescue StandardError => e
      warn "[NarrativeQuery] Error fetching dashboard stats: #{e.message}"
      { total_threads: 0, active_threads: 0, total_entities: 0, total_relationships: 0,
        unprocessed_memories: 0, entity_types: [] }
    end

    private

    # Count memories that haven't been extracted yet
    # @return [Integer]
    def unprocessed_memory_count
      extracted_ids = NarrativeExtractionLog.select(:world_memory_id)
      WorldMemory.exclude(id: extracted_ids).where { importance >= 3 }.count
    rescue StandardError => e
      warn "[NarrativeQueryService] Failed to count unprocessed memories: #{e.message}"
      0
    end
  end
end
