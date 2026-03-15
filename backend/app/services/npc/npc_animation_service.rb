# frozen_string_literal: true

# NpcAnimationService - Orchestrates LLM-powered NPC animation
#
# This service handles the automatic animation of NPCs by processing
# room broadcasts and generating contextual responses using LLMs.
#
# ASYNC DESIGN: Responses are processed immediately in Sidekiq jobs.
# There are no artificial delays - the LLM API latency (1-8 seconds) provides
# natural timing for NPC responses. Nothing blocks while waiting for the API.
#
# Animation levels:
#   - high: Responds to every IC broadcast in room (like a player)
#   - medium: Responds when mentioned; RNG chance otherwise with flash-2.5-lite
#            judgment, chance halves per recent NPC actor in last 5 minutes
#   - low: Only responds when directly mentioned
#   - off: No LLM animation (default)
#
# Usage:
#   # Called from BroadcastService.to_room for IC content
#   # Processing happens immediately in a background job
#   NpcAnimationService.process_room_broadcast(
#     room_id: 123,
#     content: "Hello merchant!",
#     sender_instance: player_instance,
#     type: :say
#   )
#
#   # Fallback: Process orphaned queue entries (called by scheduler)
#   NpcAnimationService.process_queue!
#
module NpcAnimationService
  # Animation constants - now from GameConfig::NpcAnimation
  MEDIUM_DECAY_FACTOR = GameConfig::NpcAnimation::MEDIUM_DECAY_FACTOR
  RECENT_WINDOW = GameConfig::NpcAnimation::RECENT_WINDOW_SECONDS
  MAX_RESPONSES_PER_MINUTE = GameConfig::NpcAnimation::MAX_RESPONSES_PER_MINUTE

  # ============================================
  # Anti-Spam Guards
  # ============================================

  MAX_NPC_RESPONSES_PER_HOUR = GameConfig::NpcAnimation::MAX_RESPONSES_PER_HOUR
  MAX_CONSECUTIVE_NPC_RESPONSES = GameConfig::NpcAnimation::MAX_CONSECUTIVE_RESPONSES

  # OOC bracket patterns to strip
  OOC_PATTERNS = [
    /\(\([^)]*\)\)/,  # (( OOC content ))
    /\[\[[^\]]*\]\]/  # [[ OOC content ]]
  ].freeze

  class << self
    # ============================================
    # Entry Point - Process Room Broadcast
    # ============================================

    # Process a room broadcast for potential NPC animation
    # Called from BroadcastService.to_room for IC content
    #
    # @param room_id [Integer] the room where broadcast occurred
    # @param content [String] the message content
    # @param sender_instance [CharacterInstance] who sent it
    # @param type [Symbol] message type (:say, :emote, etc.)
    def process_room_broadcast(room_id:, content:, sender_instance:, type:)
      return if room_id.nil? || content.nil? || sender_instance.nil?

      # Strip OOC content
      ic_content = strip_ooc_content(content)
      return if ic_content.nil? || ic_content.strip.empty?

      # Find animated NPCs in the room (excluding sender)
      animated_npcs = find_animated_npcs_in_room(room_id, exclude_id: sender_instance.id)
      return if animated_npcs.empty?

      # Process each NPC based on animation level
      animated_npcs.each do |npc_instance|
        process_npc_for_broadcast(
          npc_instance: npc_instance,
          content: ic_content,
          sender_instance: sender_instance,
          type: type
        )
      end
    end

    # ============================================
    # Queue Processing (Fallback)
    # ============================================

    # Process any orphaned pending queue entries
    # This is a fallback mechanism - entries are normally processed immediately
    # via process_async. This catches any that failed to start or were orphaned.
    # Called by scheduler periodically for cleanup.
    # @return [Hash] results with :processed and :failed counts
    def process_queue!
      results = { processed: 0, failed: 0 }

      pending = NpcAnimationQueue.pending_ready(limit: 5)
      unless pending.empty?
        pending.each do |entry|
          if process_queue_entry(entry)
            results[:processed] += 1
          else
            results[:failed] += 1
          end
        end
      end

      # Cleanup old entries
      NpcAnimationQueue.cleanup_old_entries

      results
    end

    # ============================================
    # Spawn Generation
    # ============================================

    # Generate outfit description for NPC on spawn
    # @param npc_instance [CharacterInstance] the spawned NPC
    # @return [String, nil] generated outfit description
    def generate_spawn_outfit(npc_instance)
      archetype = npc_instance.character&.npc_archetype
      return nil unless archetype&.should_generate_outfit?

      prompt = build_outfit_prompt(npc_instance)
      result = generate_with_fallback(
        archetype: archetype,
        prompt: prompt,
        is_first_emote: false  # Use normal model for outfit
      )

      result[:success] ? result[:text]&.strip : nil
    end

    # Generate status string for NPC on spawn
    # @param npc_instance [CharacterInstance] the spawned NPC
    # @return [String, nil] generated status (roomtitle)
    def generate_spawn_status(npc_instance)
      archetype = npc_instance.character&.npc_archetype
      return nil unless archetype&.should_generate_status?

      prompt = build_status_prompt(npc_instance)
      result = generate_with_fallback(
        archetype: archetype,
        prompt: prompt,
        is_first_emote: false
      )

      result[:success] ? result[:text]&.strip&.slice(0, 100) : nil
    end

    # ============================================
    # Content Processing Helpers
    # ============================================

    # Strip OOC content from text
    # @param text [String] text with potential OOC content
    # @return [String] text with OOC removed
    def strip_ooc_content(text)
      return nil if text.nil?

      result = text.dup
      OOC_PATTERNS.each do |pattern|
        result.gsub!(pattern, '')
      end
      result.strip
    end

    # Check if NPC is mentioned in content
    # @param npc_instance [CharacterInstance] the NPC
    # @param content [String] the message content
    # @return [Boolean]
    def mentioned_in_content?(npc_instance:, content:)
      return false if content.nil? || npc_instance.nil?

      char = npc_instance.character
      return false unless char

      # Downcase for comparison
      content_lower = content.downcase

      # Check forename
      return true if char.forename && content_lower.include?(char.forename.downcase)

      # Check surname
      return true if char.surname && content_lower.include?(char.surname.downcase)

      # Check short_desc keywords
      if char.short_desc
        # Extract significant words from short_desc (4+ chars)
        keywords = char.short_desc.downcase.split(/\s+/).select { |w| w.length >= 4 }
        return true if keywords.any? { |kw| content_lower.include?(kw) }
      end

      false
    end

    private

    # ============================================
    # NPC Discovery
    # ============================================

    # Find all animated NPCs in a room
    # @param room_id [Integer]
    # @param exclude_id [Integer, nil] character_instance_id to exclude
    # @return [Array<CharacterInstance>]
    def find_animated_npcs_in_room(room_id, exclude_id: nil)
      query = CharacterInstance
        .where(current_room_id: room_id, online: true)
        .eager(character: :npc_archetype)

      query = query.exclude(id: exclude_id) if exclude_id

      query.all.select do |ci|
        ci.character&.npc? && ci.character&.npc_archetype&.animated?
      end
    end

    # Count recently animated NPCs in a room (for RNG decay)
    # @param room_id [Integer]
    # @return [Integer]
    def count_recent_room_animators(room_id)
      CharacterInstance
        .where(current_room_id: room_id, online: true)
        .where { last_animation_at > Time.now - RECENT_WINDOW }
        .eager(character: :npc_archetype)
        .all
        .count { |ci| ci.character&.npc? && ci.character&.npc_archetype&.animated? }
    end

    # ============================================
    # Animation Level Processing
    # ============================================

    # Process an NPC for a broadcast based on animation level
    def process_npc_for_broadcast(npc_instance:, content:, sender_instance:, type:)
      # Apply anti-spam guards first
      return unless can_respond?(
        npc_instance: npc_instance,
        room_id: npc_instance.current_room_id,
        sender_instance: sender_instance
      )

      archetype = npc_instance.character.npc_archetype
      level = archetype.effective_animation_level

      case level
      when 'high'
        queue_response(
          npc_instance: npc_instance,
          trigger_type: 'high_turn',
          content: content,
          source_id: sender_instance.id
        )
      when 'medium'
        process_medium_level(
          npc_instance: npc_instance,
          content: content,
          sender_instance: sender_instance
        )
      when 'low'
        if mentioned_in_content?(npc_instance: npc_instance, content: content)
          queue_response(
            npc_instance: npc_instance,
            trigger_type: 'low_mention',
            content: content,
            source_id: sender_instance.id
          )
        end
      end
    end

    # Process medium-level animation (mention + LLM-driven probability)
    def process_medium_level(npc_instance:, content:, sender_instance:)
      archetype = npc_instance.character.npc_archetype

      # Always respond if mentioned
      if mentioned_in_content?(npc_instance: npc_instance, content: content)
        queue_response(
          npc_instance: npc_instance,
          trigger_type: 'medium_mention',
          content: content,
          source_id: sender_instance.id
        )
        return
      end

      # Check cooldown
      return if on_cooldown?(npc_instance)

      # Check room rate limit
      return unless can_respond_in_room?(npc_instance.current_room_id)

      # Get response probability from LLM (flash-2.5-lite)
      probability = judge_response_probability(npc_instance: npc_instance, content: content)
      return if probability <= 0.0

      # Apply decay based on recent NPC activity
      recent_count = count_recent_room_animators(npc_instance.current_room_id)
      adjusted_chance = probability * (MEDIUM_DECAY_FACTOR ** recent_count)

      # RNG check against LLM-determined probability
      return unless rand < adjusted_chance

      queue_response(
        npc_instance: npc_instance,
        trigger_type: 'medium_rng',
        content: content,
        source_id: sender_instance.id
      )
    end

    # ============================================
    # Async Processing
    # ============================================

    # Queue and immediately process a response asynchronously
    # No artificial delays - LLM latency provides natural timing
    def queue_response(npc_instance:, trigger_type:, content:, source_id:)
      # Create queue entry for tracking (no delay)
      entry = NpcAnimationQueue.queue_response(
        npc_instance: npc_instance,
        trigger_type: trigger_type,
        content: content,
        source_id: source_id,
        delay_seconds: 0,
        priority: trigger_type == 'high_turn' ? 3 : 5
      )

      # Process immediately in background job
      # This ensures nothing blocks while waiting for LLM API
      process_async(entry)
    end

    # Process a queue entry in a background job
    # @param entry [NpcAnimationQueue] the entry to process
    def process_async(entry)
      NpcAnimationProcessJob.perform_async(entry.id)
    rescue StandardError => e
      entry&.fail!("Async enqueue error: #{e.message}")
      warn "[NpcAnimation] Async enqueue error: #{e.message}"
      nil
    end

    # ============================================
    # Rate Limiting & Anti-Spam Guards
    # ============================================

    # Comprehensive check if NPC can respond to a broadcast
    # @param npc_instance [CharacterInstance] The NPC
    # @param room_id [Integer] The room
    # @param sender_instance [CharacterInstance] Who sent the message
    # @return [Boolean]
    def can_respond?(npc_instance:, room_id:, sender_instance:)
      # Guard 1: Don't respond to other NPCs (prevents NPC ping-pong)
      if sender_instance.character.npc?
        return false
      end

      # Guard 2: Hourly limit per NPC instance
      hourly_count = NpcAnimationQueue
        .where(character_instance_id: npc_instance.id, status: 'complete')
        .where { processed_at > Time.now - GameConfig::Timeouts::NPC_RESPONSE_WINDOW_SECONDS }
        .count
      return false if hourly_count >= MAX_NPC_RESPONSES_PER_HOUR

      # Guard 3: Consecutive NPC response limit (require PC action between)
      consecutive = count_consecutive_npc_messages(room_id)
      return false if consecutive >= MAX_CONSECUTIVE_NPC_RESPONSES

      # Guard 4: Room-wide rate limit (per minute)
      return false unless can_respond_in_room?(room_id)

      true
    end

    # Count consecutive NPC messages in recent room activity
    # @param room_id [Integer]
    # @return [Integer]
    def count_consecutive_npc_messages(room_id)
      recent = recent_room_activity(room_id: room_id, limit: 10)
      return 0 if recent.empty?

      count = 0
      recent.each do |msg|
        break unless msg[:is_npc]
        count += 1
      end
      count
    end

    # Get recent room activity for anti-spam checking
    # @param room_id [Integer]
    # @param limit [Integer]
    # @return [Array<Hash>]
    def recent_room_activity(room_id:, limit: 10)
      raw_logs = RpLog
        .where(room_id: room_id)
        .order(Sequel.desc(:logged_at), Sequel.desc(:created_at))
        .limit(limit * 5)
        .eager(:sender_character)
        .all

      # RpLog stores one row per witness; dedupe to an activity stream.
      seen = {}
      activity = []

      raw_logs.each do |log|
        timestamp = log.display_timestamp || log.created_at
        dedupe_key = [log.sender_character_id, log.content.to_s, timestamp&.to_i]
        next if seen[dedupe_key]

        seen[dedupe_key] = true
        activity << {
          content: log.content,
          character_id: log.sender_character_id,
          is_npc: log.sender_character&.npc?,
          created_at: timestamp
        }
        break if activity.length >= limit
      end

      activity
    rescue StandardError => e
      warn "[NpcAnimationService] Failed to get room context: #{e.message}"
      []
    end

    # Check if NPC is on cooldown
    def on_cooldown?(npc_instance)
      last_at = npc_instance.last_animation_at
      return false if last_at.nil?

      archetype = npc_instance.character&.npc_archetype
      cooldown = archetype&.effective_cooldown_seconds || 300

      last_at > Time.now - cooldown
    end

    # Check if room can accept more NPC responses
    def can_respond_in_room?(room_id)
      # Check pending count
      pending = NpcAnimationQueue.pending_count_for_room(room_id)
      return false if pending >= MAX_RESPONSES_PER_MINUTE

      # Check recent completions
      recent = NpcAnimationQueue.recent_complete_count_for_room(room_id)
      recent < MAX_RESPONSES_PER_MINUTE
    end

    # ============================================
    # Response Probability (for medium level)
    # ============================================

    # Use flash-2.5-lite to estimate probability NPC would respond
    # Returns a float from 0.0 to 1.0
    def judge_response_probability(npc_instance:, content:)
      archetype = npc_instance.character.npc_archetype

      prompt = GamePrompts.get(
        'npc_animation.response_probability',
        npc_name: npc_instance.character.full_name,
        personality: archetype.effective_personality_prompt,
        content: content
      )

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: { max_tokens: 50 },
        json_mode: true
      )

      if result[:success] && result[:text]
        # Strip markdown code fences if present
        text = result[:text].strip
        text = text.gsub(/\A```(?:json)?\s*/, '').gsub(/\s*```\z/, '')

        parsed = begin
          JSON.parse(text)
        rescue JSON::ParserError => e
          warn "[NpcAnimationService] Failed to parse animation probability JSON: #{e.message}"
          {}
        end
        prob = parsed['probability'].to_f
        # Clamp to valid range
        [[prob, 0.0].max, 1.0].min
      else
        0.0
      end
    end

    # ============================================
    # Queue Entry Processing
    # ============================================

    # Process a single queue entry
    # Delegates to NpcAnimationHandler for the actual work
    # @return [Boolean] true if successful, false if failed
    def process_queue_entry(entry)
      result = NpcAnimationHandler.call(entry)
      result[:success]
    rescue StandardError => e
      entry&.fail!("Error: #{e.message}")
      false
    end

    # ============================================
    # Emote Generation
    # ============================================

    # Generate an emote for the NPC
    def generate_emote(npc_instance:, context:)
      archetype = npc_instance.character.npc_archetype
      is_first = !npc_instance.animation_first_emote_done

      prompt = build_emote_prompt(npc_instance: npc_instance, context: context)

      generate_with_fallback(
        archetype: archetype,
        prompt: prompt,
        is_first_emote: is_first,
        npc_name: npc_instance.character.forename
      )
    end

    # Generate with fallback models
    def generate_with_fallback(archetype:, prompt:, is_first_emote:, npc_name: nil)
      # Select model
      model = is_first_emote ? archetype.effective_first_emote_model : archetype.effective_primary_model
      provider = NpcArchetype.provider_for_model(model)

      # Build options
      options = { max_tokens: 300, temperature: 0.8 }

      # Add partial response prefix for Claude models
      if NpcArchetype.claude_model?(model) && npc_name
        options[:partial_assistant] = "#{npc_name}'s Action: "
      end

      # Try primary model
      result = LLM::Client.generate(
        prompt: prompt,
        model: model,
        provider: provider,
        options: options
      )

      return result if result[:success]

      # Try fallbacks
      archetype.fallback_models.each do |fallback_model|
        fallback_provider = NpcArchetype.provider_for_model(fallback_model)
        fallback_options = options.dup

        if NpcArchetype.claude_model?(fallback_model) && npc_name
          fallback_options[:partial_assistant] = "#{npc_name}'s Action: "
        else
          fallback_options.delete(:partial_assistant)
        end

        result = LLM::Client.generate(
          prompt: prompt,
          model: fallback_model,
          provider: fallback_provider,
          options: fallback_options
        )

        return result if result[:success]
      end

      result
    end

    # ============================================
    # Prompt Building
    # ============================================

    # Build the emote generation prompt
    def build_emote_prompt(npc_instance:, context:)
      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character

      GamePrompts.get(
        'npc_animation.emote',
        full_name: character.full_name,
        personality: archetype.effective_personality_prompt,
        forename: character.forename,
        context: context
      )
    end

    # Build context for emote generation
    def build_context(npc_instance:, trigger_content:)
      room = npc_instance.current_room

      context = []
      context << "LOCATION: #{room&.name || 'Unknown'}"
      context << room.description if room&.description

      # Get recent room activity (last 5 messages)
      recent = recent_room_content(room_id: npc_instance.current_room_id, limit: 5)
      if !recent.nil? && !recent.empty?
        context << "\nRECENT ACTIVITY:"
        context << recent
      end

      # Add trigger content
      context << "\nTRIGGER:"
      context << trigger_content

      # Add NPC state
      if npc_instance.roomtitle && !npc_instance.roomtitle.empty?
        context << "\nYOUR STATE: #{npc_instance.roomtitle}"
      end

      context.join("\n")
    end

    # Get recent room content from RP logs
    # @return [String, nil] joined log lines, or nil on error
    def recent_room_content(room_id:, limit: 5)
      logs = RpLog.where(room_id: room_id)
                  .order(Sequel.desc(:created_at))
                  .limit(limit)
                  .all
                  .reverse

      logs.map(&:plain_text).join("\n")
    rescue StandardError => e
      warn "[NpcAnimationService] Failed to get recent room content: #{e.message}"
      nil
    end

    # Build outfit generation prompt
    def build_outfit_prompt(npc_instance)
      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character

      GamePrompts.get(
        'npc_animation.outfit',
        full_name: character.full_name,
        personality: archetype.effective_personality_prompt
      )
    end

    # Build status generation prompt
    def build_status_prompt(npc_instance)
      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character
      room = npc_instance.current_room

      GamePrompts.get(
        'npc_animation.status',
        full_name: character.full_name,
        personality: archetype.effective_personality_prompt,
        location_name: room&.name || 'this location'
      )
    end

    # ============================================
    # Broadcasting
    # ============================================

    # Broadcast NPC emote to the room
    def broadcast_npc_emote(npc_instance, emote_text)
      # Clean up any partial prefix from Claude
      cleaned = emote_text.sub(/^#{Regexp.escape(npc_instance.character.forename)}'s Action:\s*/i, '')

      # Ensure it starts with the character name
      unless cleaned.downcase.start_with?(npc_instance.character.forename.downcase)
        cleaned = "#{npc_instance.character.forename} #{cleaned}"
      end

      BroadcastService.to_room(
        npc_instance.current_room_id,
        { content: cleaned, html: cleaned },
        type: :emote,
        sender_instance: npc_instance
      )

      # Log NPC emote to character stories (use RpLoggingService directly to avoid
      # re-triggering NPC/pet animation side effects, which would cause recursion)
      RpLoggingService.log_to_room(
        npc_instance.current_room_id, cleaned,
        sender: npc_instance, type: 'emote'
      )
    end

    # Update animation tracking on the instance
    def update_animation_tracking(npc_instance)
      npc_instance.update(
        last_animation_at: Time.now,
        animation_emote_count: (npc_instance.animation_emote_count || 0) + 1,
        animation_first_emote_done: true
      )
    end
  end
end
