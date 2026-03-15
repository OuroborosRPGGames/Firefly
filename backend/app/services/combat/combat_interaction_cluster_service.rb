# frozen_string_literal: true

# Groups combat participants into clusters based on who attacks whom.
# Uses Union-Find algorithm to find connected components in the interaction graph.
#
# This allows combat narrative to be grouped into separate paragraphs where
# participants only interact with each other.
#
# @example
#   # A attacks B, B attacks A, C attacks D, D defends
#   # => Two clusters: [A, B] and [C, D]
#
#   # A attacks B, B attacks C, C attacks A
#   # => One cluster: [A, B, C] (they form a cycle)
#
class CombatInteractionClusterService
  # Cluster participants based on combat interactions
  #
  # @param events [Array<Hash>] Round events with :actor_id and :target_id
  # @return [Array<Array<Integer>>] Array of participant ID clusters
  def self.cluster(events)
    new(events).cluster
  end

  def initialize(events)
    @events = events
    @parent = {}
    @rank = {}
    @segment_map = {} # Track earliest segment for each participant
  end

  # Build clusters from combat events
  #
  # @return [Array<Array<Integer>>] Clusters sorted by earliest event segment
  def cluster
    extract_interactions.each do |actor_id, target_id, segment|
      union(actor_id, target_id)

      # Track earliest segment for each participant
      @segment_map[actor_id] = segment if !@segment_map[actor_id] || segment < @segment_map[actor_id]
      @segment_map[target_id] = segment if !@segment_map[target_id] || segment < @segment_map[target_id]
    end

    # Group participants by their root
    groups = Hash.new { |h, k| h[k] = [] }
    @parent.keys.each do |participant_id|
      root = find(participant_id)
      groups[root] << participant_id
    end

    # Sort clusters by earliest segment of any member
    groups.values.sort_by do |cluster|
      cluster.map { |id| @segment_map[id] || 0 }.min
    end
  end

  private

  # Extract (actor_id, target_id, segment) tuples from events
  #
  # @return [Array<Array>] Array of [actor_id, target_id, segment] tuples
  def extract_interactions
    interactions = []

    @events.each do |event|
      actor_id = event[:actor_id]
      target_id = event[:target_id] || event.dig(:details, :target_participant_id)
      segment = event[:segment] || 0

      # Skip events without both actor and target
      next unless actor_id && target_id

      # Skip self-targeting
      next if actor_id == target_id

      interactions << [actor_id, target_id, segment]
    end

    interactions.uniq { |a, t, _| [a, t].sort }
  end

  # Union-Find: Find with path compression
  def find(x)
    @parent[x] ||= x
    if @parent[x] != x
      @parent[x] = find(@parent[x])
    end
    @parent[x]
  end

  # Union-Find: Union by rank
  def union(x, y)
    root_x = find(x)
    root_y = find(y)

    return if root_x == root_y

    @rank[root_x] ||= 0
    @rank[root_y] ||= 0

    if @rank[root_x] < @rank[root_y]
      @parent[root_x] = root_y
    elsif @rank[root_x] > @rank[root_y]
      @parent[root_y] = root_x
    else
      @parent[root_y] = root_x
      @rank[root_x] += 1
    end
  end
end
