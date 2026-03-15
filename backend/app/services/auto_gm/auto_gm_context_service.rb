# frozen_string_literal: true

module AutoGm
  # AutoGmContextService gathers context for Auto-GM adventure generation.
  #
  # Collects:
  # - World memories from nearby locations (plot hooks)
  # - Character memories for participants (personal hooks)
  # - Nearby interesting locations for adventure settings
  # - Local NPCs for potential involvement
  # - Participant context (skills, relationships, backgrounds)
  # - Room context (description, exits, features)
  #
  class AutoGmContextService
    # Context gathering limits (from centralized config)
    MAX_NEARBY_MEMORIES = GameConfig::AutoGm::CONTEXT[:max_nearby_memories]
    MAX_CHARACTER_MEMORIES = GameConfig::AutoGm::CONTEXT[:max_character_memories]
    MAX_LOCATION_SEARCH_DEPTH = GameConfig::AutoGm::CONTEXT[:max_location_search_depth]
    MAX_NEARBY_LOCATIONS = GameConfig::AutoGm::CONTEXT[:max_nearby_locations]

    # Interesting room types for adventure locations (from centralized config)
    INTERESTING_ROOM_TYPES = RoomTypeConfig.tagged(:interesting).freeze

    class << self
      # Gather all context needed for adventure generation
      # @param session [AutoGmSession] the session to gather context for
      # @return [Hash] context data
      def gather(session)
        room = session.starting_room
        participants = session.participant_instances

        # Run independent query groups in parallel
        location_results = {}
        participant_results = {}
        room_result = {}

        threads = []

        # Group 1: Location-based queries (independent of participants)
        threads << Thread.new do
          Timeout.timeout(10, Timeout::Error) do
            location_results[:nearby_memories] = gather_nearby_memories(room)
            location_results[:nearby_locations] = discover_nearby_locations(room)
            location_results[:local_npcs] = gather_local_npcs(room)
            location_results[:narrative_threads] = gather_narrative_threads(room)
          end
        rescue Timeout::Error
          warn '[AutoGmContextService] Location context worker timed out after 10s'
        rescue StandardError => e
          warn "[AutoGmContextService] Location thread error: #{e.message}"
        end

        # Group 2: Participant-based queries (independent of location queries)
        threads << Thread.new do
          Timeout.timeout(10, Timeout::Error) do
            participant_results[:character_memories] = gather_character_memories(participants)
            participant_results[:participant_context] = build_participant_context(participants, session)
            participant_results[:participant_narrative] = gather_participant_narrative(participants)
          end
        rescue Timeout::Error
          warn '[AutoGmContextService] Participant context worker timed out after 10s'
        rescue StandardError => e
          warn "[AutoGmContextService] Participant thread error: #{e.message}"
        end

        # Group 3: Room context (fast, independent)
        threads << Thread.new do
          Timeout.timeout(10, Timeout::Error) do
            room_result[:room_context] = build_room_context(room)
          end
        rescue Timeout::Error
          warn '[AutoGmContextService] Room context worker timed out after 10s'
        rescue StandardError => e
          warn "[AutoGmContextService] Room thread error: #{e.message}"
        end

        # Wait for all threads to finish (they self-timeout via Timeout.timeout)
        threads.each { |t| t.join }

        # Build available stats list
        available_stats = session.available_stats

        location_results.merge(participant_results).merge(room_result).merge(
          available_stats: available_stats,
          stat_names: available_stats.map { |s| s[:name] },
          gathered_at: Time.now
        )
      end

      # Gather context for a specific room without a session
      # @param room [Room] the room to gather context for
      # @param participants [Array<CharacterInstance>] characters involved
      # @return [Hash] context data
      def gather_for_room(room, participants = [])
        location_results = {}
        participant_results = {}

        threads = []
        threads << Thread.new do
          Timeout.timeout(10, Timeout::Error) do
            location_results[:nearby_memories] = gather_nearby_memories(room)
            location_results[:nearby_locations] = discover_nearby_locations(room)
            location_results[:local_npcs] = gather_local_npcs(room)
            location_results[:narrative_threads] = gather_narrative_threads(room)
          end
        rescue Timeout::Error
          warn '[AutoGmContextService] Location context worker timed out after 10s'
        rescue StandardError => e
          warn "[AutoGmContextService] Location thread error: #{e.message}"
        end

        threads << Thread.new do
          Timeout.timeout(10, Timeout::Error) do
            participant_results[:character_memories] = gather_character_memories(participants)
            participant_results[:participant_context] = build_participant_context(participants)
            participant_results[:participant_narrative] = gather_participant_narrative(participants)
          end
        rescue Timeout::Error
          warn '[AutoGmContextService] Participant context worker timed out after 10s'
        rescue StandardError => e
          warn "[AutoGmContextService] Participant thread error: #{e.message}"
        end

        # Wait for all threads to finish (they self-timeout via Timeout.timeout)
        threads.each { |t| t.join }

        location_results.merge(participant_results).merge(
          room_context: build_room_context(room),
          available_stats: [],
          stat_names: [],
          gathered_at: Time.now
        )
      end

      private

      # Gather active narrative threads relevant to this room
      # @param room [Room]
      # @return [Array<Hash>] thread summaries
      def gather_narrative_threads(room)
        return [] unless defined?(NarrativeQueryService)

        threads = NarrativeQueryService.active_threads(location: room, limit: 5)
        threads.map do |t|
          entity_names = t.entities.first(5).map(&:name)

          # Enrich with PC participant info
          pc_participants = t.narrative_thread_entities_dataset.all.filter_map do |te|
            ne = NarrativeEntity[te.narrative_entity_id]
            next unless ne&.canonical_type == 'Character' && ne&.canonical_id

            char = Character[ne.canonical_id]
            next unless char && !char.npc?

            rep = ReputationService.reputation_for(char, knowledge_tier: 1)
            { name: char.full_name, role: te.role, reputation: rep }
          end

          {
            id: t.id,
            name: t.name,
            summary: t.summary,
            status: t.status,
            importance: t.importance,
            themes: t.themes,
            entity_names: entity_names,
            pc_participants: pc_participants,
            last_activity: t.last_activity_at&.iso8601
          }
        end
      rescue StandardError => e
        warn "[AutoGmContext] Error gathering narrative threads: #{e.message}"
        []
      end

      # Gather narrative profiles for PC participants (threads, reputation)
      # @param participants [Array<CharacterInstance>]
      # @return [Array<Hash>] narrative profile per PC
      def gather_participant_narrative(participants)
        return [] unless defined?(NarrativeEntity)
        return [] if participants.nil? || participants.empty?

        participants.filter_map do |p|
          char = p.character
          next unless char && !char.npc?

          entity = NarrativeEntity.find_by_canonical('Character', char.id)
          next unless entity

          # Get active threads
          thread_entities = NarrativeThreadEntity.where(narrative_entity_id: entity.id).all
          thread_ids = thread_entities.map(&:narrative_thread_id)
          active_threads = NarrativeThread.where(id: thread_ids).active_threads.by_importance.limit(5).all

          threads_data = active_threads.map do |t|
            te = thread_entities.find { |x| x.narrative_thread_id == t.id }
            { name: t.name, status: t.status, role: te&.role, summary: t.summary }
          end

          reputation = ReputationService.reputation_for(char, knowledge_tier: 1)

          {
            name: char.full_name,
            reputation: reputation,
            active_threads: threads_data,
            mention_count: entity.mention_count,
            importance: entity.importance
          }
        end
      rescue StandardError => e
        warn "[AutoGmContext] Error gathering participant narrative: #{e.message}"
        []
      end

      # Query WorldMemory for events near this location
      # @param room [Room] starting room
      # @return [Array<Hash>] memory summaries
      def gather_nearby_memories(room)
        return [] unless room&.location

        # Get memories from this location
        memories = WorldMemory
          .for_location(room.location, limit: MAX_NEARBY_MEMORIES, days: 30)
          .all

        memories.map do |mem|
          {
            id: mem.id,
            summary: mem.summary,
            importance: mem.importance || 5,
            characters_involved: mem.characters.map { |c| DisplayHelper.display_name(c) },
            primary_room: mem.primary_room&.name,
            publicity_level: mem.publicity_level,
            memory_at: mem.memory_at&.iso8601,
            relevance_score: mem.relevance_score
          }
        end
      rescue StandardError => e
        warn "[AutoGmContextService] gather_nearby_memories error: #{e.message}"
        []
      end

      # Query memories involving the participants
      # @param participants [Array<CharacterInstance>] character instances
      # @return [Array<Hash>] memory summaries
      def gather_character_memories(participants)
        return [] if participants.nil? || participants.empty?

        characters = participants.map(&:character).compact
        return [] if characters.empty?

        memories = WorldMemory
          .for_characters(characters, limit: MAX_CHARACTER_MEMORIES * participants.size)
          .all

        memories.map do |mem|
          {
            id: mem.id,
            summary: mem.summary,
            importance: mem.importance || 5,
            characters_involved: mem.characters.map { |c| DisplayHelper.display_name(c) },
            location: mem.primary_room&.location&.name,
            memory_at: mem.memory_at&.iso8601
          }
        end
      rescue StandardError => e
        warn "[AutoGmContextService] gather_character_memories error: #{e.message}"
        []
      end

      # Discover nearby interesting locations using a single BFS pass
      # @param room [Room] starting room
      # @return [Array<Hash>] location data
      def discover_nearby_locations(room)
        return [] unless room

        interesting_types = Set.new(INTERESTING_ROOM_TYPES)
        locations_found = []
        visited_room_ids = Set.new([room.id])
        visited_locations = Set.new
        deadline = Time.now + 5 # 5 second time limit

        # BFS using spatial navigation
        queue = [[room, 0]] # [room, depth]
        while queue.any? && locations_found.size < MAX_NEARBY_LOCATIONS
          break if Time.now > deadline

          current_room, depth = queue.shift
          next if depth > MAX_LOCATION_SEARCH_DEPTH

          # Check if this room is interesting
          if depth > 0 && interesting_types.include?(current_room.room_type) && !visited_locations.include?(current_room.location_id)
            visited_locations.add(current_room.location_id)
            locations_found << {
              type: current_room.room_type,
              room_id: current_room.id,
              room_name: current_room.name,
              room_description: truncate_text(current_room.description, 200),
              location_id: current_room.location_id,
              location_name: current_room.location&.name,
              distance: depth
            }
          end

          # Expand neighbors using spatial adjacency
          neighbor_exits = current_room.navigable_exits rescue []
          neighbor_exits.each do |ex|
            neighbor = ex[:room]
            next unless neighbor
            next if visited_room_ids.include?(neighbor.id)

            visited_room_ids.add(neighbor.id)
            queue << [neighbor, depth + 1]
          end
        end

        locations_found.sort_by { |l| l[:distance] }
      rescue StandardError => e
        warn "[AutoGmContextService] discover_nearby_locations error: #{e.message}"
        []
      end

      # Gather NPCs in this room and adjacent rooms
      # @param room [Room] starting room
      # @return [Array<Hash>] NPC data
      def gather_local_npcs(room)
        return [] unless room

        # Get adjacent room IDs using spatial navigation
        adjacent_exits = room.navigable_exits rescue []
        adjacent_room_ids = adjacent_exits.map { |e| e[:room]&.id }.compact
        all_room_ids = [room.id] + adjacent_room_ids

        # Find NPCs in these rooms (is_npc is on Character, not CharacterInstance)
        npcs = CharacterInstance
          .where(current_room_id: all_room_ids)
          .where(online: true)
          .eager(:character, :current_room)
          .all
          .select { |ci| ci.character&.npc? }

        npcs.map do |npc|
          char = npc.character
          archetype = char.respond_to?(:npc_archetype) ? char.npc_archetype : nil

          {
            id: npc.id,
            character_id: char.id,
            name: DisplayHelper.display_name(char),
            archetype: archetype&.name,
            archetype_id: archetype&.id,
            room_id: npc.current_room_id,
            room_name: npc.current_room&.name,
            disposition: archetype&.respond_to?(:default_disposition) ? archetype.default_disposition : 'neutral',
            is_in_starting_room: npc.current_room_id == room.id
          }
        end
      rescue StandardError => e
        warn "[AutoGmContextService] gather_local_npcs error: #{e.message}"
        []
      end

      # Build context about each participant
      # @param participants [Array<CharacterInstance>] character instances
      # @return [Array<Hash>] participant context
      def build_participant_context(participants, session = nil)
        return [] if participants.nil? || participants.empty?

        participants.map do |p|
          char = p.character
          next nil unless char

          context = {
            instance_id: p.id,
            character_id: char.id,
            name: DisplayHelper.display_name(char),
            is_npc: char.npc?
          }

          # Add optional fields if they exist
          context[:level] = char.level if char.respond_to?(:level)
          context[:char_class] = char.char_class if char.respond_to?(:char_class)
          context[:race] = char.race if char.respond_to?(:race)
          context[:background] = truncate_text(char.background, 300) if char.respond_to?(:background) && char.background
          context[:notable_skills] = char.top_skills(3) if char.respond_to?(:top_skills)
          context[:relationships] = char.significant_relationships(5) if char.respond_to?(:significant_relationships)

          # Add stat values if session has a stat block
          if session
            context[:stat_values] = session.stat_values_for(p)
          end

          context
        end.compact
      rescue StandardError => e
        warn "[AutoGmContextService] build_participant_context error: #{e.message}"
        []
      end

      # Build context about the starting room
      # @param room [Room] the room
      # @return [Hash] room context
      def build_room_context(room)
        return {} unless room

        context = {
          id: room.id,
          name: room.name,
          description: truncate_text(room.description, 500),
          room_type: room.room_type
        }

        # Add location info
        if room.location
          context[:location_name] = room.location.name
          context[:location_id] = room.location_id
        end

        # Add exits using spatial navigation
        exits_data = room.navigable_exits rescue []
        context[:exits] = exits_data.map do |e|
          {
            direction: e[:direction],
            to_room_name: e[:room]&.name,
            to_room_type: e[:room]&.room_type
          }
        end

        # Add NPCs present (is_npc is on Character, not CharacterInstance)
        context[:npcs_present] = room.character_instances_dataset
          .where(online: true)
          .eager(:character)
          .all
          .select { |ci| ci.character&.npc? }
          .map { |ci| DisplayHelper.character_display_name(ci) }

        # Add visible places/features if the room has them
        if room.respond_to?(:visible_places)
          context[:notable_features] = room.visible_places.map(&:name)
        end

        context
      rescue StandardError => e
        warn "[AutoGmContextService] build_room_context error: #{e.message}"
        {}
      end

      # Truncate text to a maximum length
      # @param text [String, nil] text to truncate
      # @param max_length [Integer] maximum length
      # @return [String]
      def truncate_text(text, max_length)
        return '' if text.nil? || text.empty?
        return text if text.length <= max_length

        "#{text[0..max_length - 4]}..."
      end
    end
  end
end
