# frozen_string_literal: true

# Safe abstraction over Apache AGE Cypher queries.
# All AGE interactions go through this service.
# Gracefully returns empty results if AGE is not installed.
module NarrativeGraphService
  class << self
    # Check if Apache AGE is available
    # @return [Boolean]
    def age_available?
      return @age_available unless @age_available.nil?

      @age_available = DB.fetch("SELECT 1 FROM pg_extension WHERE extname = 'age'").any?
    rescue StandardError => e
      warn "[NarrativeGraph] AGE availability check failed: #{e.message}"
      @age_available = false
    end

    # Reset cached AGE availability (for testing)
    def reset_cache!
      @age_available = nil
    end

    # ========================================
    # Node CRUD
    # ========================================

    # Upsert an entity node in the graph
    # @param entity [NarrativeEntity]
    def upsert_entity_node(entity)
      return unless age_available?

      execute_cypher(
        "MERGE (e:Entity {pg_id: #{entity.id}}) " \
        "SET e.name = #{sanitize_param(entity.name)}, " \
        "e.entity_type = #{sanitize_param(entity.entity_type)}, " \
        "e.importance = #{sanitize_param(entity.importance)}"
      )
    rescue StandardError => e
      warn "[NarrativeGraph] Error upserting entity node: #{e.message}"
    end

    # Upsert a memory node in the graph
    # @param memory [WorldMemory]
    def upsert_memory_node(memory)
      return unless age_available?

      execute_cypher(
        "MERGE (m:Memory {pg_id: #{memory.id}}) " \
        "SET m.summary = #{sanitize_param(memory.summary.to_s[0, 200])}, " \
        "m.importance = #{sanitize_param(memory.importance)}"
      )
    rescue StandardError => e
      warn "[NarrativeGraph] Error upserting memory node: #{e.message}"
    end

    # Remove an entity node
    # @param entity_id [Integer]
    def remove_entity_node(entity_id)
      return unless age_available?

      execute_cypher("MATCH (e:Entity {pg_id: #{entity_id.to_i}}) DETACH DELETE e")
    rescue StandardError => e
      warn "[NarrativeGraph] Error removing entity node: #{e.message}"
    end

    # ========================================
    # Edge CRUD
    # ========================================

    # Upsert a relationship edge between entities
    # @param relationship [NarrativeRelationship]
    def upsert_relationship_edge(relationship)
      return unless age_available?

      execute_cypher(
        "MATCH (a:Entity {pg_id: #{relationship.source_entity_id.to_i}}), " \
        "(b:Entity {pg_id: #{relationship.target_entity_id.to_i}}) " \
        "MERGE (a)-[r:RELATES_TO {rel_type: #{sanitize_param(relationship.relationship_type)}}]->(b) " \
        "SET r.strength = #{sanitize_param(relationship.strength)}, " \
        "r.pg_id = #{relationship.id.to_i}"
      )
    rescue StandardError => e
      warn "[NarrativeGraph] Error upserting relationship edge: #{e.message}"
    end

    # Upsert a mention edge (entity -> memory)
    # @param entity_id [Integer]
    # @param memory_id [Integer]
    # @param role [String]
    def upsert_mention_edge(entity_id, memory_id, role: 'mentioned')
      return unless age_available?

      execute_cypher(
        "MATCH (e:Entity {pg_id: #{entity_id.to_i}}), " \
        "(m:Memory {pg_id: #{memory_id.to_i}}) " \
        "MERGE (e)-[r:MENTIONED_IN]->(m) " \
        "SET r.role = #{sanitize_param(role)}"
      )
    rescue StandardError => e
      warn "[NarrativeGraph] Error upserting mention edge: #{e.message}"
    end

    # ========================================
    # Query
    # ========================================

    # Find connected components (entity clusters)
    # Uses AGE if available, falls back to relational BFS
    # @param min_size [Integer]
    # @return [Array<Array<Integer>>] arrays of entity IDs
    def find_connected_components(min_size: 3)
      if age_available?
        find_components_via_age(min_size)
      else
        find_clusters_relational(min_size: min_size)
      end
    rescue StandardError => e
      warn "[NarrativeGraph] Error finding components: #{e.message}"
      find_clusters_relational(min_size: min_size)
    end

    # Find shortest paths between two entities
    # @param entity_a_id [Integer]
    # @param entity_b_id [Integer]
    # @param max_hops [Integer]
    # @return [Array<Hash>] path data
    def find_paths(entity_a_id, entity_b_id, max_hops: 4)
      return [] unless age_available?

      rows = execute_cypher(
        "MATCH p = shortestPath((a:Entity {pg_id: #{entity_a_id.to_i}})" \
        "-[*1..#{max_hops.to_i}]-" \
        "(b:Entity {pg_id: #{entity_b_id.to_i}})) " \
        "RETURN [n in nodes(p) | n.pg_id] AS node_ids"
      )

      rows.map { |r| { node_ids: r[:node_ids] } }
    rescue StandardError => e
      warn "[NarrativeGraph] Error finding paths: #{e.message}"
      []
    end

    # Get 1-2 hop neighborhood of an entity
    # @param entity_id [Integer]
    # @param depth [Integer]
    # @return [Hash] { nodes: [], edges: [] }
    def entity_neighborhood(entity_id, depth: 2)
      return { nodes: [], edges: [] } unless age_available?

      rows = execute_cypher(
        "MATCH (a:Entity {pg_id: #{entity_id.to_i}})-[r*1..#{depth.to_i}]-(b:Entity) " \
        "RETURN DISTINCT b.pg_id AS entity_id, b.name AS name, b.entity_type AS entity_type"
      )

      { nodes: rows, edges: [] }
    rescue StandardError => e
      warn "[NarrativeGraph] Error querying neighborhood: #{e.message}"
      { nodes: [], edges: [] }
    end

    # Find entities that co-occur with a given entity in memories
    # @param entity_id [Integer]
    # @param limit [Integer]
    # @return [Array<Hash>]
    def co_occurring_entities(entity_id, limit: 20)
      # This is more efficient via relational query
      memory_ids = NarrativeEntityMemory
        .where(narrative_entity_id: entity_id)
        .select_map(:world_memory_id)
      return [] if memory_ids.empty?

      NarrativeEntityMemory
        .where(world_memory_id: memory_ids)
        .exclude(narrative_entity_id: entity_id)
        .group_and_count(:narrative_entity_id)
        .order(Sequel.desc(:count))
        .limit(limit)
        .all
        .map { |r| { entity_id: r[:narrative_entity_id], co_occurrence_count: r[:count] } }
    end

    # ========================================
    # Relational Fallback
    # ========================================

    # BFS-based connected component detection using NarrativeRelationship table
    # @param min_size [Integer]
    # @return [Array<Array<Integer>>] arrays of entity IDs
    def find_clusters_relational(min_size: 3)
      # Build adjacency list from current relationships
      adjacency = Hash.new { |h, k| h[k] = Set.new }
      NarrativeRelationship.current.each do |rel|
        adjacency[rel.source_entity_id].add(rel.target_entity_id)
        adjacency[rel.target_entity_id].add(rel.source_entity_id)
      end

      return [] if adjacency.empty?

      # BFS to find connected components
      visited = Set.new
      components = []

      adjacency.each_key do |node|
        next if visited.include?(node)

        component = []
        queue = [node]
        while queue.any?
          current = queue.shift
          next if visited.include?(current)

          visited.add(current)
          component << current

          adjacency[current].each do |neighbor|
            queue << neighbor unless visited.include?(neighbor)
          end
        end

        components << component if component.size >= min_size
      end

      components
    end

    private

    # Execute a Cypher query via AGE
    # @param cypher [String]
    # @return [Array<Hash>]
    def execute_cypher(cypher, return_results: true)
      ensure_age_context!

      if return_results && cypher.include?('RETURN')
        sql = "SELECT * FROM ag_catalog.cypher('narrative_graph', $$ #{cypher} $$) AS (result agtype)"
        DB.fetch(sql).all.map { |row| parse_agtype(row[:result]) }
      else
        sql = "SELECT * FROM ag_catalog.cypher('narrative_graph', $$ #{cypher} $$) AS (result agtype)"
        DB.run(sql)
        []
      end
    end

    # Set up AGE search path
    def ensure_age_context!
      DB.run("SET search_path = ag_catalog, '$user', public")
      DB.run("LOAD 'age'") rescue nil # May not need explicit load on all setups
    end

    # Parse AGE agtype result
    # @param value [String, Object]
    # @return [Object]
    def parse_agtype(value)
      return value unless value.is_a?(String)

      # AGE returns JSON-like strings
      JSON.parse(value, symbolize_names: true)
    rescue JSON::ParserError
      value
    end

    # Sanitize a parameter for Cypher embedding
    # @param value [Object]
    # @return [String]
    def sanitize_param(value)
      case value
      when Integer
        value.to_s
      when Float
        value.to_s
      when NilClass
        'null'
      when TrueClass, FalseClass
        value.to_s
      when String
        # Escape single quotes and backslashes for Cypher strings
        escaped = value.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
        "'#{escaped}'"
      else
        sanitize_param(value.to_s)
      end
    end

    # Find connected components via AGE graph traversal
    # @param min_size [Integer]
    # @return [Array<Array<Integer>>]
    def find_components_via_age(min_size)
      # Get all entity nodes and their connections
      rows = execute_cypher(
        "MATCH (a:Entity)-[:RELATES_TO]-(b:Entity) " \
        "RETURN DISTINCT a.pg_id AS source, b.pg_id AS target"
      )

      return [] if rows.empty?

      # Build adjacency and run BFS on results
      adjacency = Hash.new { |h, k| h[k] = Set.new }
      rows.each do |row|
        src = row.is_a?(Hash) ? (row[:source] || row['source']) : row
        tgt = row.is_a?(Hash) ? (row[:target] || row['target']) : row
        next unless src && tgt

        adjacency[src.to_i].add(tgt.to_i)
        adjacency[tgt.to_i].add(src.to_i)
      end

      visited = Set.new
      components = []

      adjacency.each_key do |node|
        next if visited.include?(node)

        component = []
        queue = [node]
        while queue.any?
          current = queue.shift
          next if visited.include?(current)

          visited.add(current)
          component << current

          adjacency[current].each do |neighbor|
            queue << neighbor unless visited.include?(neighbor)
          end
        end

        components << component if component.size >= min_size
      end

      components
    end
  end
end
