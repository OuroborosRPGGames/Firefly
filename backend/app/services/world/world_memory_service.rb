# frozen_string_literal: true

# WorldMemoryService handles world memory creation, storage, and retrieval.
# Captures RP sessions and converts them into searchable memories with:
# - LLM-generated summaries (flash-2.5-lite)
# - Embeddings for semantic search
# - Time-based decay for relevance ranking
# - Abstraction hierarchy for memory compression
#
# Usage:
#   WorldMemoryService.track_ic_message(room_id:, content:, sender:, type:)
#   WorldMemoryService.handle_character_movement(character_instance:, from_room:, to_room:)
#   WorldMemoryService.retrieve_relevant(query:, limit:)
#
module WorldMemoryService
  extend CharacterLookupHelper
  extend StringHelper

  MEMORY_EMBEDDING_TYPE = 'world_memory'
  ABSTRACTION_THRESHOLD = GameConfig::NpcMemory::ABSTRACTION_THRESHOLD
  MAX_ABSTRACTION_LEVEL = GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL
  RAW_LOG_RETENTION_MONTHS = GameConfig::NpcMemory::RAW_LOG_RETENTION_MONTHS
  MAX_ASYNC_JOBS = 8
  SUMMARY_MODEL = 'gemini-3.1-flash-lite-preview'
  SUMMARY_PROVIDER = 'google_gemini'

  # Message types to track for world memory
  IC_MESSAGE_TYPES = %i[say emote whisper think attempt pose action].freeze

  class << self
    @async_mutex = Mutex.new
    @async_in_flight = 0

    # ========================================
    # Session Tracking (called from BroadcastService)
    # ========================================

    # Process an IC message for world memory tracking
    # @param room_id [Integer]
    # @param content [String]
    # @param sender [CharacterInstance]
    # @param type [Symbol]
    # @param is_private [Boolean]
    # @return [WorldMemorySession, nil]
    def track_ic_message(room_id:, content:, sender:, type:, is_private: false)
      return if blank?(content)
      return unless ic_message_type?(type)
      return unless sender&.character

      room = Room[room_id]
      return unless room

      # Check character count in matching event context (need 2+ for a session)
      char_count = context_character_count(room_id: room_id, event_id: sender.in_event_id)
      return if char_count < 2

      # Find or create active session
      session = find_or_create_session(room: room, sender: sender)
      return unless session

      # Handle privacy - if private mode, mark session and stop tracking
      if is_private || sender.private_mode?
        session.mark_private!
        return session
      end

      # Update publicity level based on room
      session.update_publicity!(determine_publicity(room, sender))

      # Append to log buffer
      sender_name = sender.character.full_name
      session.append_log!(
        content,
        sender_name: sender_name,
        type: type
      )

      # Track character activity
      session.add_character!(sender.character)
      session.increment_character_messages!(sender.character)

      # Track room if different from primary
      session.add_room!(room)
      session.update_room_activity!(room)

      session
    rescue StandardError => e
      warn "[WorldMemory] Error tracking IC message: #{e.message}"
      warn e.backtrace.first(5).join("\n")
      nil
    end

    # Handle character movement for session tracking
    # @param character_instance [CharacterInstance]
    # @param from_room [Room]
    # @param to_room [Room]
    def handle_character_movement(character_instance:, from_room:, to_room:)
      return unless from_room && to_room && character_instance&.character

      event_id = character_instance.in_event_id

      # Check if leaving an active session
      from_session = WorldMemorySession.active_for_room_context(from_room.id, event_id)
      if from_session
        from_session.remove_character!(character_instance.character)

        # Check remaining active characters
        remaining = from_session.active_character_count
        if remaining <= 1
          # Session ends - finalize if sufficient, otherwise abandon
          finalize_session_async(from_session)
        end
      end

      # Check if joining an existing session in the destination room
      to_session = WorldMemorySession.active_for_room_context(to_room.id, event_id)
      if to_session
        to_session.add_character!(character_instance.character)
        to_session.add_room!(to_room)
      elsif context_character_count(room_id: to_room.id, event_id: event_id) >= 2
        # Create a child session when RP flow splits into a new room context.
        parent_context = from_session ? generate_split_context(from_session) : nil
        to_session = create_session_with_retry(
          room_id: to_room.id,
          event_id: event_id,
          create_attributes: {
            room_id: to_room.id,
            event_id: event_id,
            started_at: Time.now,
            last_activity_at: Time.now,
            status: 'active',
            publicity_level: determine_publicity(to_room, character_instance),
            parent_session_id: from_session&.id,
            parent_context: parent_context
          }
        )
        return unless to_session

        to_session.add_character!(character_instance.character)
        to_session.add_room!(to_room)
      end
    rescue StandardError => e
      warn "[WorldMemory] Error handling movement: #{e.message}"
    end

    # ========================================
    # Session Finalization
    # ========================================

    # Finalize a session and create world memory
    # @param session [WorldMemorySession]
    # @return [WorldMemory, nil]
    def finalize_session(session)
      return nil unless session
      return nil if session.finalized? || session.abandoned?
      return nil unless session.sufficient_for_memory?

      session.finalize!

      # Skip if all private
      if session.has_private_content
        session.abandon!
        return nil
      end

      # Generate summary using flash-2.5-lite
      summary = generate_summary(session)
      if summary.nil? || summary.strip.empty?
        session.abandon!
        return nil
      end

      # Calculate importance
      importance = calculate_importance(session)

      # Create the memory
      memory = WorldMemory.create(
        summary: summary,
        raw_log: session.log_buffer,
        importance: importance,
        message_count: session.message_count,
        started_at: session.started_at,
        ended_at: session.ended_at || Time.now,
        memory_at: session.ended_at || Time.now,
        publicity_level: session.publicity_level,
        source_type: session.event_id ? 'event' : 'session',
        source_id: session.event_id || session.id,
        parent_memory_id: find_parent_memory_id(session),
        parent_context: session.parent_context
      )

      # Link characters
      session.session_characters.each do |sc|
        next unless sc.character

        if sc.character.npc?
          memory.add_npc!(sc.character, role: 'involved')
        else
          memory.add_character!(
            sc.character,
            role: 'participant',
            message_count: sc.message_count || 0
          )
        end
      end

      # Link locations
      session.session_rooms.each_with_index do |sr, idx|
        next unless sr.room

        memory.add_location!(
          sr.room,
          is_primary: idx == 0,
          message_count: sr.message_count || 0
        )
      end

      # Store embedding
      store_memory_embedding(memory)

      # Check world memory triggers
      TriggerService.check_world_memory_triggers(world_memory: memory)

      # Narrative extraction for important memories
      if defined?(NarrativeExtractionService) &&
         (memory.importance >= GameConfig::Narrative::EXTRACTION[:importance_threshold_comprehensive] ||
          memory.source_type == 'event')
        run_async('narrative extraction') { NarrativeExtractionService.extract_comprehensive(memory) }
      end

      # Mark session complete
      session.mark_finalized!

      # Check for abstraction
      check_and_abstract!

      memory
    rescue StandardError => e
      warn "[WorldMemory] Error finalizing session: #{e.message}"
      session&.abandon!
      nil
    end

    # Finalize session asynchronously
    # @param session [WorldMemorySession]
    def finalize_session_async(session)
      run_async('session finalize') { finalize_session(session) }
    end

    # Create world memory from event in the bounded async queue
    # @param event [Event]
    def create_from_event_async(event)
      run_async('event memory creation') { create_from_event(event) }
    end

    # ========================================
    # Event/Activity Integration
    # ========================================

    # Create world memory from completed event
    # @param event [Event]
    # @return [WorldMemory, nil]
    def create_from_event(event)
      return nil unless event&.completed?

      logs = RpLog.where(event_id: event.id)
                  .where(is_private: false)
                  .order(:created_at)
                  .all

      return nil if logs.size < WorldMemorySession::MIN_MESSAGES_FOR_MEMORY

      # Build log content
      log_content = logs.map do |log|
        sender_name = log.sender_character&.full_name || 'Unknown'
        "[#{log.created_at.strftime('%H:%M')}] #{sender_name} (#{log.log_type}): #{log.text}"
      end.join("\n")

      # Determine publicity
      publicity = event.logs_visible_to == 'public' ? 'public_event' : 'private_event'

      # Generate summary
      summary = generate_summary_from_text(log_content, context: "Event: #{event.name}")
      return nil if summary.nil? || summary.strip.empty?

      memory = WorldMemory.create(
        summary: summary,
        raw_log: log_content,
        importance: 7,  # Events are important
        message_count: logs.size,
        started_at: event.started_at || event.starts_at,
        ended_at: event.ended_at || Time.now,
        memory_at: event.ended_at || Time.now,
        publicity_level: publicity,
        source_type: 'event',
        source_id: event.id
      )

      # Link characters from attendees
      if event.respond_to?(:event_attendees)
        event.event_attendees.each do |attendee|
          next unless attendee.character

          if attendee.character.npc?
            memory.add_npc!(attendee.character, role: 'involved')
          else
            memory.add_character!(attendee.character, role: 'participant')
          end
        end
      end

      # Link room
      memory.add_location!(event.room, is_primary: true) if event.room

      store_memory_embedding(memory)
      check_and_abstract!

      memory
    rescue StandardError => e
      warn "[WorldMemory] Error creating from event: #{e.message}"
      nil
    end

    # Create world memory from completed activity/mission
    # @param instance [ActivityInstance]
    # @return [WorldMemory, nil]
    def create_from_activity(instance)
      return nil unless instance
      return nil unless instance.respond_to?(:completed?) && instance.completed?

      # Get activity logs
      logs = ActivityLog.where(activity_instance_id: instance.id).order(:created_at).all
      return nil if logs.size < 3

      # Build log content
      log_content = logs.map { |l| l.respond_to?(:text) ? l.text : l.content.to_s }.compact.join("\n")

      # Generate summary
      activity_name = instance.activity&.respond_to?(:display_name) ? instance.activity.display_name : "Activity ##{instance.id}"
      summary = generate_summary_from_text(log_content, context: "Mission: #{activity_name}")
      return nil if summary.nil? || summary.strip.empty?

      memory = WorldMemory.create(
        summary: summary,
        raw_log: log_content,
        importance: 6,
        message_count: logs.size,
        started_at: instance.created_at,
        ended_at: instance.updated_at || Time.now,
        memory_at: Time.now,
        publicity_level: 'public',
        source_type: 'activity',
        source_id: instance.id
      )

      # Link participants
      if instance.respond_to?(:participants)
        instance.participants.each do |p|
          char = Character[p.respond_to?(:char_id) ? p.char_id : p.character_id]
          next unless char

          if char.npc?
            memory.add_npc!(char, role: 'involved')
          else
            memory.add_character!(char, role: 'participant')
          end
        end
      end

      # Link room
      memory.add_location!(instance.room, is_primary: true) if instance.room

      store_memory_embedding(memory)

      memory
    rescue StandardError => e
      warn "[WorldMemory] Error creating from activity: #{e.message}"
      nil
    end

    # ========================================
    # Retrieval
    # ========================================

    # Retrieve relevant memories using semantic search
    # @param query [String]
    # @param limit [Integer]
    # @param include_private [Boolean]
    # @return [Array<WorldMemory>]
    def retrieve_relevant(query:, limit: 10, include_private: false)
      result = LLM::Client.embed(text: query, input_type: 'query')
      return [] unless result[:success]

      similar = Embedding.similar_to(
        result[:embedding],
        limit: limit * 2,
        content_type: MEMORY_EMBEDDING_TYPE,
        threshold: 0.4
      )

      memory_ids = similar.map { |s| s[:embedding].content_id }
      memories = if include_private
                   WorldMemory.where(id: memory_ids)
                 else
                   WorldMemory.searchable.where(id: memory_ids)
                 end

      # Sort by similarity order
      sorted_ids = memory_ids
      memories.all
              .sort_by { |m| sorted_ids.index(m.id) || Float::INFINITY }
              .first(limit)
    rescue StandardError => e
      warn "[WorldMemory] Error retrieving memories: #{e.message}"
      []
    end

    # Retrieve memories for a location
    # @param room [Room]
    # @param limit [Integer]
    def memories_at_location(room:, limit: 10)
      WorldMemory.for_room(room, limit: limit).all
    end

    # Retrieve world memories relevant to an NPC for context building
    # Returns memories the NPC witnessed or would have heard about
    # @param npc [Character] The NPC character
    # @param query [String] Search query for semantic relevance
    # @param room [Room] NPC's current room (for location-based filtering)
    # @param limit [Integer] Max memories to return
    # @return [Array<WorldMemory>]
    def retrieve_for_npc(npc:, query:, room: nil, limit: 5)
      return [] unless npc

      candidates = []
      seen_ids = Set.new

      # 1. Direct participation: NPC was involved in the memory
      direct_memory_ids = WorldMemoryCharacter.where(character_id: npc.id).select_map(:world_memory_id)
      if defined?(WorldMemoryNpc)
        direct_memory_ids.concat(WorldMemoryNpc.where(character_id: npc.id).select_map(:world_memory_id))
      end
      direct = WorldMemory.where(id: direct_memory_ids.uniq)
                          .order(Sequel.desc(:memory_at))
                          .limit(limit * 2)
                          .all
      direct.each do |m|
        seen_ids << m.id
      end
      candidates.concat(direct.map { |m| { memory: m, source: :direct, weight: 1.0, distance: 0 } })

      # 2. Semantic search for topically relevant memories
      if query && !query.strip.empty?
        semantic = retrieve_relevant(query: query, limit: limit * 2, include_private: false)
        semantic.each do |m|
          next if seen_ids.include?(m.id)

          # Calculate distance for semantic matches
          distance = room ? calculate_memory_distance(room, m) : Float::INFINITY
          seen_ids << m.id
          candidates << { memory: m, source: :semantic, weight: 0.8, distance: distance }
        end
      end

      # 3. Location-based: Memories from nearby locations (distance-weighted)
      if room
        nearby_memories = retrieve_nearby_memories(room, limit: limit * 3)
        nearby_memories.each do |mem_data|
          next if seen_ids.include?(mem_data[:memory].id)

          seen_ids << mem_data[:memory].id
          candidates << {
            memory: mem_data[:memory],
            source: :location,
            weight: mem_data[:weight],
            distance: mem_data[:distance]
          }
        end
      end

      # 4. Relationship-based: Memories involving PCs the NPC has relationships with
      relationship_chars = NpcRelationship.for_npc(npc).map(&:pc_character_id)
      if relationship_chars.any?
        rel_memory_ids = WorldMemoryCharacter
          .where(character_id: relationship_chars)
          .select(:world_memory_id)
        relationship_memories = WorldMemory.searchable
                                           .where(id: rel_memory_ids)
                                           .order(Sequel.desc(:memory_at))
                                           .limit(limit)
                                           .all
        relationship_memories.each do |m|
          next if seen_ids.include?(m.id)

          distance = room ? calculate_memory_distance(room, m) : Float::INFINITY
          seen_ids << m.id
          candidates << { memory: m, source: :relationship, weight: 0.5, distance: distance }
        end
      end

      # Score and filter candidates
      scored = candidates.map do |c|
        m = c[:memory]

        # Base weight from source
        score = c[:weight]

        # Apply distance modifier for non-direct sources
        unless c[:source] == :direct
          distance_modifier = calculate_distance_modifier(c[:distance])
          score *= distance_modifier
        end

        # Publicity modifier (public spreads more, with distance interaction)
        case m.publicity_level
        when 'public', 'public_event'
          score *= 1.0
        when 'semi_public'
          score *= 0.7
        when 'secluded'
          # Secluded only spreads locally
          score *= (c[:distance] < 10 ? 0.4 : 0.1)
        else
          score *= 0.1
        end

        # Importance modifier
        score *= (m.importance || 5) / 10.0

        # Recency modifier (more recent = more likely heard about)
        age_days = (Time.now - (m.memory_at || Time.now)).to_f / 86400
        recency = [1.0 - (age_days / 90.0), 0.1].max  # 90-day decay for gossip
        score *= recency

        # Direct knowledge always gets through
        score = 1.0 if c[:source] == :direct

        { memory: m, score: score, source: c[:source], distance: c[:distance] }
      end

      # Filter by probability for non-direct knowledge
      filtered = scored.select do |s|
        s[:source] == :direct || s[:score] > 0.3 || rand < s[:score]
      end

      # Sort by score and return top memories
      filtered.sort_by { |s| -s[:score] }
              .map { |s| s[:memory] }
              .first(limit)
    rescue StandardError => e
      warn "[WorldMemory] Error retrieving for NPC: #{e.message}"
      []
    end

    # Retrieve memories from nearby locations with distance-based weighting
    # @param room [Room] Reference room
    # @param limit [Integer] Max memories to return
    # @return [Array<Hash>] Array of { memory:, weight:, distance: }
    def retrieve_nearby_memories(room, limit: 20)
      return [] unless room

      location = room.location
      zone = location&.zone
      return [] unless zone

      # Get all memory locations in the same zone
      zone_location_ids = Location.where(zone_id: zone.id).select(:id)
      zone_room_ids = Room.where(location_id: zone_location_ids).select(:id)
      zone_memory_ids = WorldMemoryLocation.where(room_id: zone_room_ids).select(:world_memory_id)

      # Also get memories from neighboring zones (same world)
      world = zone.world
      nearby_memory_ids = zone_memory_ids
      if world
        # Get zones in the same world
        world_zone_ids = Zone.where(world_id: world.id).select(:id)
        world_location_ids = Location.where(zone_id: world_zone_ids).select(:id)
        world_room_ids = Room.where(location_id: world_location_ids).select(:id)
        nearby_memory_ids = WorldMemoryLocation.where(room_id: world_room_ids).select(:world_memory_id)
      end

      memories = WorldMemory.searchable
                            .where(id: nearby_memory_ids)
                            .order(Sequel.desc(:memory_at))
                            .limit(limit)
                            .all

      memories.map do |m|
        distance = calculate_memory_distance(room, m)
        weight = calculate_location_weight(distance)
        { memory: m, weight: weight, distance: distance }
      end
    end

    # Calculate distance between a room and a memory's primary location
    # Returns a normalized distance score (0 = same room, higher = farther)
    # @param room [Room] Reference room
    # @param memory [WorldMemory] Memory to check
    # @return [Float] Distance score
    def calculate_memory_distance(room, memory)
      memory_room = memory.primary_room
      return Float::INFINITY unless memory_room

      # Same room = 0 distance
      return 0 if room.id == memory_room.id

      room_location = room.location
      memory_location = memory_room.location

      return Float::INFINITY unless room_location && memory_location

      # Same location (building) = small distance
      return 1 if room_location.id == memory_location.id

      room_zone = room_location.zone
      memory_zone = memory_location.zone

      return Float::INFINITY unless room_zone && memory_zone

      # Same zone = calculate hex distance
      if room_zone.id == memory_zone.id
        if room_location.has_globe_hex? && memory_location.has_globe_hex?
          hex_distance = calculate_location_hex_distance(room_location, memory_location)
          return 2 + hex_distance
        end
        return 5 # Same area but no hex coords
      end

      # Different zones: estimate from room coordinates if available.
      if room_location.latitude && room_location.longitude &&
         memory_location.latitude && memory_location.longitude
        geo_distance = calculate_geographic_distance(
          { longitude: room_location.longitude, latitude: room_location.latitude },
          { longitude: memory_location.longitude, latitude: memory_location.latitude }
        )
        # Normalize: ~100 units = 1 degree of latitude (~111 km)
        return 10 + (geo_distance * 100)
      end

      # Fallback to zone-level geographic bounds center when room coords are absent.
      if room_zone.has_geographic_bounds? && memory_zone.has_geographic_bounds?
        geo_distance = calculate_geographic_distance(
          zone_geographic_center(room_zone),
          zone_geographic_center(memory_zone)
        )
        return 10 + (geo_distance * 100)
      end

      # Different area, no geographic data = far
      50
    end

    # Calculate hex distance between two locations using great circle distance
    # @param origin [Location] starting location
    # @param destination [Location] ending location
    # @return [Integer] approximate hex distance
    def calculate_location_hex_distance(origin, destination)
      return 0 unless origin.latitude && origin.longitude && destination.latitude && destination.longitude

      # Use great circle distance from WorldHex
      distance_rad = WorldHex.great_circle_distance_rad(
        origin.latitude, origin.longitude,
        destination.latitude, destination.longitude
      )

      # Convert radians to approximate hex units
      # Earth radius ~6371km, 1 hex ~5km
      (distance_rad * 6371 / 5).round
    end

    # Calculate geographic distance between two center points
    # Uses Haversine formula approximation for small distances
    # @param point1 [Hash] { longitude:, latitude: }
    # @param point2 [Hash] { longitude:, latitude: }
    # @return [Float] Distance in degrees (approximate)
    def calculate_geographic_distance(point1, point2)
      return Float::INFINITY unless point1 && point2

      lon1 = point1[:longitude] || point1['longitude']
      lat1 = point1[:latitude] || point1['latitude']
      lon2 = point2[:longitude] || point2['longitude']
      lat2 = point2[:latitude] || point2['latitude']

      return Float::INFINITY unless lon1 && lat1 && lon2 && lat2

      # Simple Euclidean distance in degrees (good enough for relative comparison)
      Math.sqrt((lon2 - lon1)**2 + (lat2 - lat1)**2)
    end

    # Geographic center from legacy zone bounds.
    # @param zone [Zone]
    # @return [Hash, nil] { longitude:, latitude: }
    def zone_geographic_center(zone)
      return nil unless zone&.has_geographic_bounds?

      {
        longitude: (zone.min_longitude + zone.max_longitude) / 2.0,
        latitude: (zone.min_latitude + zone.max_latitude) / 2.0
      }
    end

    # Calculate location weight based on distance
    # @param distance [Float] Distance score
    # @return [Float] Weight from 0.1 to 1.0
    def calculate_location_weight(distance)
      case distance
      when 0         then 1.0   # Same room
      when 0..1      then 0.95  # Same location/building
      when 1..5      then 0.8   # Same area, nearby
      when 5..15     then 0.6   # Same area, farther
      when 15..30    then 0.4   # Neighboring area
      when 30..50    then 0.25  # Distant area
      else                0.1   # Very far
      end
    end

    # Calculate distance modifier for scoring
    # @param distance [Float] Distance score
    # @return [Float] Modifier from 0.1 to 1.5
    def calculate_distance_modifier(distance)
      return 1.0 if distance.nil? || distance == Float::INFINITY

      case distance
      when 0         then 1.5  # Same room bonus
      when 0..1      then 1.2  # Same building bonus
      when 1..5      then 1.0  # Nearby, no modifier
      when 5..15     then 0.8  # Some distance penalty
      when 15..30    then 0.5  # Farther penalty
      when 30..50    then 0.3  # Distant penalty
      else                0.1  # Very far penalty
      end
    end

    # Format world memories for NPC context
    # @param memories [Array<WorldMemory>]
    # @param npc [Character] The NPC (to check direct involvement)
    # @return [String]
    def format_for_npc_context(memories, npc: nil)
      return '' if memories.empty?

      memories.map do |m|
        # Check if NPC was directly involved
        direct = npc && (
          WorldMemoryCharacter.first(
            world_memory_id: m.id,
            character_id: npc.id
          ) ||
          (defined?(WorldMemoryNpc) && WorldMemoryNpc.first(
            world_memory_id: m.id,
            character_id: npc.id
          ))
        )

        prefix = if direct
                   '[You witnessed]'
                 elsif m.recent?(days: 7)
                   '[Recent gossip]'
                 else
                   '[You heard]'
                 end

        # Add location context if available
        location = m.primary_room&.name
        location_str = location ? " (at #{location})" : ''

        "#{prefix}#{location_str} #{m.summary}"
      end.join("\n")
    end

    # Retrieve memories involving a character
    # @param character [Character]
    # @param limit [Integer]
    def memories_for_character(character:, limit: 10)
      WorldMemory.for_character(character, limit: limit).all
    end

    # ========================================
    # Narrative Thread Context (for NPCs)
    # ========================================

    # Retrieve narrative thread context relevant to an NPC
    # @param npc [Character] the NPC
    # @param room [Room] current room
    # @param limit [Integer] max threads
    # @return [Array<NarrativeThread>]
    def retrieve_thread_context_for_npc(npc:, room:, limit: 3)
      return [] unless defined?(NarrativeQueryService)

      threads = NarrativeQueryService.active_threads(status: %w[active climax], limit: limit * 3)
      return [] if threads.empty?

      # Score threads by importance and proximity
      scored = threads.filter_map do |thread|
        # Only include threads with searchable memories (avoid loading all memories)
        searchable_memories = WorldMemory.searchable
          .where(id: thread.narrative_thread_memories_dataset.select(:world_memory_id))
          .limit(20)
          .all
        next if searchable_memories.empty?

        # Proximity: check if thread has activity near this room
        proximity_score = if room
                           thread_rooms = searchable_memories.filter_map(&:primary_room)
                           if thread_rooms.any? { |r| r.id == room.id }
                             1.0
                           elsif room.location && thread_rooms.any? { |r| r.location_id == room.location_id }
                             0.7
                           else
                             0.3
                           end
                         else
                           0.5
                         end

        # Recency: how recent is the latest activity?
        last_activity = thread.last_activity_at || thread.created_at
        days_ago = (Time.now - last_activity) / 86_400.0
        recency_score = [1.0 - (days_ago / 30.0), 0.1].max

        total_score = (thread.importance / 10.0) * proximity_score * recency_score
        { thread: thread, score: total_score }
      end

      scored.sort_by { |s| -s[:score] }.first(limit).map { |s| s[:thread] }
    rescue StandardError => e
      warn "[WorldMemory] Error retrieving thread context for NPC: #{e.message}"
      []
    end

    # Format narrative threads for NPC context
    # @param threads [Array<NarrativeThread>]
    # @return [String]
    def format_thread_context_for_npc(threads)
      return '' if threads.nil? || threads.empty?

      threads.map do |thread|
        prefix = case thread.status
                 when 'climax' then '[Major ongoing event]'
                 when 'active' then '[Current storyline]'
                 when 'emerging' then '[Emerging story]'
                 else '[Recent story]'
                 end
        "#{prefix} #{thread.name}: #{thread.summary}"
      end.join("\n")
    end

    # ========================================
    # Abstraction
    # ========================================

    # Abstract memories at a level into a summary at the next level
    # @param level [Integer] Level to abstract from
    # @return [WorldMemory, nil]
    def abstract_memories!(level: 1)
      return nil if level >= MAX_ABSTRACTION_LEVEL

      memories = WorldMemory.unabstracted_at_level(level)
                            .limit(ABSTRACTION_THRESHOLD)
                            .all

      return nil if memories.size < ABSTRACTION_THRESHOLD

      # Generate summary
      summary = generate_abstraction_summary(memories)
      return nil if summary.nil? || summary.strip.empty?

      abstract = create_abstraction_memory(
        summary: summary,
        memories: memories,
        level: level,
        branch_type: 'global',
        branch_reference_id: nil
      )

      # Link to abstraction (batch update)
      WorldMemory.where(id: memories.map(&:id)).update(abstracted_into_id: abstract.id)
      record_abstraction_edges!(
        source_memories: memories,
        target_memory: abstract,
        branch_type: 'global',
        branch_reference_id: nil
      )

      store_memory_embedding(abstract)

      abstract
    end

    # Check all levels and abstract if needed
    def check_and_abstract!
      (1...MAX_ABSTRACTION_LEVEL).each do |level|
        while WorldMemory.needs_abstraction?(level)
          break unless abstract_memories!(level: level)
        end

        check_and_abstract_branches!(level: level)
      end
    end

    # Check branch-specific DAG abstraction (location, character, npc, lore).
    # Uses WorldMemoryAbstraction records for branch idempotency.
    # @param level [Integer]
    def check_and_abstract_branches!(level:)
      abstract_location_branches!(level: level)
      abstract_character_branches!(level: level)
      abstract_npc_branches!(level: level)
      abstract_lore_branches!(level: level)
    end

    # ========================================
    # Cleanup (Scheduler Jobs)
    # ========================================

    # Purge expired raw logs (6 months old)
    # @return [Integer] Count of purged logs
    def purge_expired_raw_logs!
      count = 0
      WorldMemory.expired_raw_logs.each do |memory|
        memory.purge_raw_log!
        count += 1
      end
      count
    end

    # Finalize stale sessions (2+ hours inactive)
    # @return [Integer] Count of finalized/abandoned sessions
    def finalize_stale_sessions!
      count = 0
      WorldMemorySession.stale_sessions.each do |session|
        if session.sufficient_for_memory?
          finalize_session(session)
        else
          session.abandon!
        end
        count += 1
      end
      count
    end

    # Apply decay to old memories (reduce importance)
    # @return [Integer] Count of decayed memories
    def apply_decay!
      cutoff = Time.now - (365 * 24 * 3600)  # 1 year old
      WorldMemory.where { memory_at < cutoff }
                 .where { importance > 1 }
                 .update(importance: Sequel[:importance] - 1)
    end

    private

    # ========================================
    # Private Helpers
    # ========================================

    def find_or_create_session(room:, sender:)
      event_id = sender.in_event_id
      session = WorldMemorySession.active_for_room_context(room.id, event_id)
      return session if session

      # Create new session
      create_session_with_retry(
        room_id: room.id,
        event_id: event_id,
        create_attributes: {
          room_id: room.id,
          event_id: event_id,
          started_at: Time.now,
          last_activity_at: Time.now,
          status: 'active',
          publicity_level: determine_publicity(room, sender)
        }
      )
    end

    def create_session_with_retry(room_id:, event_id:, create_attributes:)
      WorldMemorySession.create(create_attributes)
    rescue Sequel::UniqueConstraintViolation
      WorldMemorySession.active_for_room_context(room_id, event_id)
    end

    def determine_publicity(room, sender)
      room_level = if room.private_mode?
                     'private'
                   elsif room.respond_to?(:secluded?) && room.secluded?
                     'secluded'
                   elsif room.respond_to?(:semi_public?) && room.semi_public?
                     'semi_public'
                   else
                     'public'
                   end

      return room_level unless sender.in_event_id

      event = Event[sender.in_event_id]
      return room_level unless event

      event_level = event.logs_visible_to == 'public' ? 'public_event' : 'private_event'
      WorldMemory.more_restrictive_publicity(room_level, event_level)
    end

    def context_character_count(room_id:, event_id:)
      context_characters_in_room(room_id: room_id, event_id: event_id).count
    end

    def context_characters_in_room(room_id:, event_id:)
      CharacterInstance.where(
        current_room_id: room_id,
        online: true,
        in_event_id: event_id
      )
    end

    def abstract_location_branches!(level:)
      return unless defined?(WorldMemoryLocation)

      # Only check rooms that have enough memories to potentially need abstraction
      candidate_room_ids = WorldMemoryLocation
        .select(:room_id)
        .group(:room_id)
        .having(Sequel.lit('COUNT(*) >= ?', ABSTRACTION_THRESHOLD))
        .select_map(:room_id)

      candidate_room_ids.each do |room_id|
        loop do
          memories = WorldMemoryLocation.unabstracted_memories_for_room(room_id, level)
                                       .limit(ABSTRACTION_THRESHOLD)
                                       .all
          break if memories.size < ABSTRACTION_THRESHOLD

          created = abstract_branch_group!(
            branch_type: 'location',
            branch_reference_id: room_id,
            memories: memories,
            level: level
          )
          break unless created
        end
      end
    end

    def abstract_character_branches!(level:)
      return unless defined?(WorldMemoryCharacter)

      candidate_character_ids = WorldMemoryCharacter
        .select(:character_id)
        .group(:character_id)
        .having(Sequel.lit('COUNT(*) >= ?', ABSTRACTION_THRESHOLD))
        .select_map(:character_id)

      candidate_character_ids.each do |character_id|
        loop do
          memories = WorldMemoryCharacter.unabstracted_memories_for_character(character_id, level)
                                        .limit(ABSTRACTION_THRESHOLD)
                                        .all
          break if memories.size < ABSTRACTION_THRESHOLD

          created = abstract_branch_group!(
            branch_type: 'character',
            branch_reference_id: character_id,
            memories: memories,
            level: level
          )
          break unless created
        end
      end
    end

    def abstract_npc_branches!(level:)
      return unless defined?(WorldMemoryNpc)

      candidate_character_ids = WorldMemoryNpc
        .select(:character_id)
        .group(:character_id)
        .having(Sequel.lit('COUNT(*) >= ?', ABSTRACTION_THRESHOLD))
        .select_map(:character_id)

      candidate_character_ids.each do |character_id|
        loop do
          memories = WorldMemoryNpc.unabstracted_memories_for_npc(character_id, level)
                                  .limit(ABSTRACTION_THRESHOLD)
                                  .all
          break if memories.size < ABSTRACTION_THRESHOLD

          created = abstract_branch_group!(
            branch_type: 'npc',
            branch_reference_id: character_id,
            memories: memories,
            level: level
          )
          break unless created
        end
      end
    end

    def abstract_lore_branches!(level:)
      return unless defined?(WorldMemoryLore)

      candidate_helpfile_ids = WorldMemoryLore
        .select(:helpfile_id)
        .group(:helpfile_id)
        .having(Sequel.lit('COUNT(*) >= ?', ABSTRACTION_THRESHOLD))
        .select_map(:helpfile_id)

      candidate_helpfile_ids.each do |helpfile_id|
        loop do
          memories = WorldMemoryLore.unabstracted_memories_for_lore(helpfile_id, level)
                                   .limit(ABSTRACTION_THRESHOLD)
                                   .all
          break if memories.size < ABSTRACTION_THRESHOLD

          created = abstract_branch_group!(
            branch_type: 'lore',
            branch_reference_id: helpfile_id,
            memories: memories,
            level: level
          )
          break unless created
        end
      end
    end

    def abstract_branch_group!(branch_type:, branch_reference_id:, memories:, level:)
      summary = generate_abstraction_summary(memories)
      return nil if summary.nil? || summary.strip.empty?

      abstract = create_abstraction_memory(
        summary: summary,
        memories: memories,
        level: level,
        branch_type: branch_type,
        branch_reference_id: branch_reference_id
      )

      decorate_branch_memory!(abstract, branch_type: branch_type, branch_reference_id: branch_reference_id)
      record_abstraction_edges!(
        source_memories: memories,
        target_memory: abstract,
        branch_type: branch_type,
        branch_reference_id: branch_reference_id
      )
      store_memory_embedding(abstract)

      abstract
    rescue StandardError => e
      warn "[WorldMemory] Branch abstraction failed (#{branch_type}:#{branch_reference_id}): #{e.message}"
      nil
    end

    def create_abstraction_memory(summary:, memories:, level:, branch_type:, branch_reference_id:)
      WorldMemory.create(
        summary: summary,
        importance: memories.map(&:importance).max,
        message_count: memories.sum(&:message_count),
        started_at: memories.map(&:started_at).min,
        ended_at: memories.map(&:ended_at).max,
        memory_at: Time.now,
        abstraction_level: level + 1,
        publicity_level: most_restrictive_publicity(memories),
        branch_type: branch_type,
        branch_reference_id: branch_reference_id
      )
    end

    def record_abstraction_edges!(source_memories:, target_memory:, branch_type:, branch_reference_id:)
      return unless defined?(WorldMemoryAbstraction)

      source_memories.each do |memory|
        WorldMemoryAbstraction.find_or_create(
          source_memory_id: memory.id,
          target_memory_id: target_memory.id,
          branch_type: branch_type,
          branch_reference_id: branch_reference_id
        )
      end
    end

    def decorate_branch_memory!(memory, branch_type:, branch_reference_id:)
      case branch_type
      when 'location'
        room = Room[branch_reference_id] if defined?(Room)
        memory.add_location!(room, is_primary: true) if room
      when 'character'
        character = Character[branch_reference_id] if defined?(Character)
        memory.add_character!(character, role: 'mentioned', message_count: 0) if character && !character.npc?
      when 'npc'
        character = Character[branch_reference_id] if defined?(Character)
        memory.add_npc!(character, role: 'mentioned') if character
      when 'lore'
        helpfile = Helpfile[branch_reference_id] if defined?(Helpfile)
        memory.add_lore!(helpfile, reference_type: 'central') if helpfile
      end
    end

    def ic_message_type?(type)
      IC_MESSAGE_TYPES.include?(type.to_sym)
    end

    def generate_summary(session)
      return nil if session.log_buffer.nil? || session.log_buffer.strip.empty?

      room_name = session.room&.name || 'Unknown Location'
      generate_summary_from_text(session.log_buffer, context: "RP Session in #{room_name}")
    end

    def generate_summary_from_text(text, context: nil)
      return nil if text.nil? || text.strip.empty?

      context_str = context ? "Context: #{context}\n\n" : ''
      prompt = GamePrompts.get('memory.session_summary',
                               context: context_str,
                               log_content: text[0, 4000])

      result = LLM::Client.generate(
        prompt: prompt,
        model: SUMMARY_MODEL,
        provider: SUMMARY_PROVIDER,
        options: { temperature: 0.3 }
      )

      result[:success] ? result[:text]&.strip : nil
    rescue StandardError => e
      warn "[WorldMemory] Error generating summary: #{e.message}"
      nil
    end

    def generate_abstraction_summary(memories)
      content = memories.map { |m| "- #{m.summary}" }.join("\n")

      prompt = GamePrompts.get('memory.world_abstraction', memories: content)

      result = LLM::Client.generate(
        prompt: prompt,
        model: SUMMARY_MODEL,
        provider: SUMMARY_PROVIDER,
        options: { temperature: 0.3 }
      )

      result[:success] ? result[:text]&.strip : nil
    rescue StandardError => e
      warn "[WorldMemory] Error generating abstraction: #{e.message}"
      nil
    end

    def generate_split_context(session)
      return nil if session.log_buffer.nil? || session.log_buffer.strip.empty?

      prompt = GamePrompts.get('memory.split_context', log_content: session.log_buffer[0, 2000])

      result = LLM::Client.generate(
        prompt: prompt,
        model: SUMMARY_MODEL,
        provider: SUMMARY_PROVIDER,
        options: { temperature: 0.3 }
      )

      result[:success] ? result[:text]&.strip : nil
    rescue StandardError => e
      warn "[WorldMemoryService] Failed to generate summary: #{e.message}"
      nil
    end

    def calculate_importance(session)
      base = 5
      base += 1 if session.message_count >= 20
      base += 1 if session.message_count >= 50
      base += 1 if session.session_characters.count >= 3
      base += 1 if session.event_id  # Events are more important
      [base, 10].min
    end

    def store_memory_embedding(memory)
      Embedding.store(
        content_type: MEMORY_EMBEDDING_TYPE,
        content_id: memory.id,
        text: memory.summary,
        room_id: memory.primary_room&.id,
        input_type: 'document'
      )
    rescue StandardError => e
      warn "[WorldMemory] Warning: Failed to store embedding: #{e.message}"
    end

    def find_parent_memory_id(session)
      return nil unless session.parent_session_id

      parent = WorldMemorySession[session.parent_session_id]
      return nil unless parent&.finalized?

      parent_memory = WorldMemory.first(source_type: 'session', source_id: parent.id)
      return parent_memory.id if parent_memory

      # Find memory created from parent session
      WorldMemory.first(
        source_type: 'session',
        started_at: parent.started_at,
        ended_at: parent.ended_at
      )&.id
    end

    def most_restrictive_publicity(memories)
      memories.map(&:publicity_level).compact.reduce do |acc, level|
        WorldMemory.more_restrictive_publicity(acc, level)
      end || 'public'
    end

    def run_async(label)
      should_spawn = false

      @async_mutex ||= Mutex.new
      @async_in_flight ||= 0
      @async_mutex.synchronize do
        if @async_in_flight < MAX_ASYNC_JOBS
          @async_in_flight += 1
          should_spawn = true
        end
      end

      unless should_spawn
        warn "[WorldMemory] Async queue saturated for #{label}; running inline"
        yield
        return nil
      end

      Thread.new do
        begin
          yield
        rescue StandardError => e
          warn "[WorldMemory] Async #{label} error: #{e.message}"
        ensure
          @async_mutex ||= Mutex.new
          @async_in_flight ||= 0
          @async_mutex.synchronize do
            @async_in_flight -= 1 if @async_in_flight.positive?
          end
        end
      end
    end
  end
end
