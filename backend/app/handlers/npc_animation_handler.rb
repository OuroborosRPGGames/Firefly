# frozen_string_literal: true

require_relative '../lib/time_format_helper'

# NpcAnimationHandler - Callback handler for NPC animation queue entries
#
# This handler processes individual queue entries, generating and broadcasting
# NPC emotes in response to room activity. Called by NpcAnimationService.process_queue!
#
# Enhanced with:
# - NpcMemoryService for storing and retrieving NPC memories (Voyage AI + pgvector)
# - NpcRelationship for tracking sentiment and trust with PCs
# - Helpfile.search_lore for world lore context
#
# Usage:
#   NpcAnimationHandler.call(queue_entry)
#
class NpcAnimationHandler
  extend ResultHandler
  extend TimeFormatHelper

  class << self
    # Process a single animation queue entry
    # @param entry [NpcAnimationQueue] the queue entry to process
    # @return [Hash] result with :success, :message, and optional :emote
    def call(entry)
      return error('No queue entry provided') unless entry

      # Mark as processing - returns false if record was deleted
      return error('Queue entry no longer exists') unless entry.start_processing!

      # Validate NPC is still in position
      npc_instance = entry.character_instance
      unless valid_npc_state?(npc_instance, entry)
        entry.fail!('NPC no longer in room')
        return error('NPC no longer in room')
      end

      # Ensure NPC has temporal continuity (catch-up after gaps)
      begin
        NpcCatchupService.ensure_caught_up!(npc_instance)
      rescue StandardError => e
        warn "[NpcAnimationHandler] Catch-up failed (non-blocking): #{e.message}"
      end

      # Generate the emote with proper message history
      result = generate_and_broadcast_emote(npc_instance, entry)

      if result[:success]
        entry.complete!(result[:emote])

        # Puppet suggestions are only suggestions; do not mutate gameplay state
        # until staff explicitly commits with pemote.
        if result[:puppeted]
          return success('Puppet suggestion queued', data: { emote: result[:emote], puppeted: true })
        end

        update_animation_tracking(npc_instance, result[:emote])

        # Post-animation processing (memory/relationship updates)
        post_animation_update(npc_instance, entry, result[:emote])

        # Check NPC triggers asynchronously (don't block response)
        TriggerService.check_npc_triggers_async(
          npc_instance: npc_instance,
          emote_content: result[:emote],
          arranged_scene_id: arranged_scene_id_for(
            npc_character_id: npc_instance.character_id,
            trigger_source_id: entry.trigger_source_id
          )
        )

        # Check if following NPC should leave their leader
        if npc_instance.following_id
          NpcLeadershipService.check_and_handle_leave(npc_instance: npc_instance)
        end

        success('Animation processed successfully', data: { emote: result[:emote] })
      else
        entry.fail!(result[:error])
        error(result[:error])
      end
    rescue StandardError => e
      entry&.fail!("Error: #{e.message}")
      error("Handler error: #{e.message}")
    end

    # Apply NPC animation side effects when a puppeteer explicitly commits an emote.
    # This keeps suggestion generation side-effect free while preserving behavior
    # once staff chooses to emit.
    def apply_committed_emote_side_effects(npc_instance:, emote_text:, suggestion_text: nil)
      return if npc_instance.nil? || StringHelper.blank?(emote_text)

      update_animation_tracking(npc_instance, emote_text)

      entry = find_matching_puppet_queue_entry(
        npc_instance: npc_instance,
        emote_text: emote_text,
        suggestion_text: suggestion_text
      )

      # Relationship/memory updates need the original trigger source.
      post_animation_update(npc_instance, entry, emote_text) if entry

      TriggerService.check_npc_triggers_async(
        npc_instance: npc_instance,
        emote_content: emote_text,
        arranged_scene_id: arranged_scene_id_for(
          npc_character_id: npc_instance.character_id,
          trigger_source_id: entry&.trigger_source_id
        )
      )

      if npc_instance.following_id
        NpcLeadershipService.check_and_handle_leave(npc_instance: npc_instance)
      end
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to apply committed emote side effects: #{e.message}"
    end

    private

    alias_method :format_time_gap, :format_duration_gap

    # Check if NPC instance is still valid for this entry
    def valid_npc_state?(npc_instance, entry)
      npc_instance &&
        npc_instance.online &&
        npc_instance.current_room_id == entry.room_id
    end

    # Build static context for emote generation (goes in system prompt)
    # Includes room info, people present, lore, memories, relationships
    def build_context(npc_instance, entry)
      room = npc_instance.current_room
      npc = npc_instance.character

      parts = []

      # Current conditions
      parts << "CURRENT CONDITIONS:"
      parts << "Time: #{Time.now.strftime('%I:%M %p')}"
      parts << "Area: #{room&.name || 'Unknown'}"
      parts << room.description if room&.description

      # People present (PC descriptions)
      pc_descriptions = build_pc_descriptions(npc_instance)
      if pc_descriptions && !pc_descriptions.empty?
        parts << "\nPEOPLE PRESENT:"
        parts << pc_descriptions
      end

      # PC reputation context (what NPC knows about people here)
      reputation_context = fetch_reputation_context(npc_instance)
      if reputation_context && !reputation_context.empty?
        parts << "\nWHAT YOU KNOW ABOUT PEOPLE HERE:"
        parts << reputation_context
      end

      # Get relevant lore (world knowledge)
      lore_context = fetch_lore_context(entry.trigger_content)
      if lore_context && !lore_context.empty?
        parts << "\nRELEVANT BACKGROUND INFORMATION:"
        parts << lore_context
      end

      # Get relevant memories (3+ hours old to avoid echo)
      memory_context = fetch_memory_context(npc, entry.trigger_content)
      if memory_context && !memory_context.empty?
        parts << "\nRELEVANT MEMORIES:"
        parts << memory_context
      end

      # Get relationship context with the trigger source
      relationship_context = fetch_relationship_context(npc_instance, entry)
      if relationship_context && !relationship_context.empty?
        parts << "\nRELATIONSHIPS:"
        parts << relationship_context
      end

      # Get relevant world memories (witnessed or heard about)
      world_memory_context = fetch_world_memory_context(npc, entry.trigger_content, npc_instance.current_room)
      if world_memory_context && !world_memory_context.empty?
        parts << "\nWORLD EVENTS YOU KNOW ABOUT:"
        parts << world_memory_context
      end

      # Get narrative thread context (ongoing storylines)
      narrative_context = fetch_narrative_context(npc, npc_instance.current_room)
      if narrative_context && !narrative_context.empty?
        parts << "\nONGOING STORYLINES YOU'RE AWARE OF:"
        parts << narrative_context
      end

      # Get relevant clues if talking to a PC
      clue_context = fetch_clue_context(npc, entry)
      if clue_context && !clue_context.empty?
        parts << "\nCLUES YOU KNOW (share naturally if relevant):"
        parts << clue_context
      end

      # NPC's current state
      if npc_instance.roomtitle && !npc_instance.roomtitle.empty?
        parts << "\nYOUR CURRENT STATE: #{npc_instance.roomtitle}"
      end

      parts.join("\n")
    end

    # Build message history with proper user/assistant alternation
    # - NPC's own actions → assistant role
    # - Other characters' actions → user role
    # - First message must be user
    # - Last message must be user (for non-Claude) or partial_assistant (for Claude)
    # @return [Array<Hash>] messages array with :role and :content
    def build_message_history(npc_instance, entry)
      npc_character_id = npc_instance.character_id

      # Fetch recent RP logs witnessed by this NPC only.
      logs = RpLog.where(character_instance_id: npc_instance.id)
                  .order(Sequel.desc(:logged_at), Sequel.desc(:created_at))
                  .limit(12)
                  .all
                  .reverse

      # Build initial messages with role assignment
      initial_messages = []
      last_time = nil

      logs.each do |log|
        char = log.sender_character || log.character_instance&.character
        char_name = char&.forename || char&.full_name || 'Someone'

        # Add time gap marker (stored temporarily, merged into user content later)
        if last_time
          timestamp = log.display_timestamp
          time_gap = format_duration_gap(last_time, timestamp)
          initial_messages << { role: 'time_gap', content: time_gap } if time_gap
        end
        last_time = log.display_timestamp

        # Format content and assign role
        content = "#{char_name}'s action: #{log.text}"

        # NPC's own actions → assistant, others → user
        is_npc_sender = if log.sender_character_id
                          log.sender_character_id == npc_character_id
                        else
                          log.character_instance&.character_id == npc_character_id
                        end

        if is_npc_sender
          initial_messages << { role: 'assistant', content: content }
        else
          initial_messages << { role: 'user', content: content }
        end
      end

      # Add the triggering content as user message
      initial_messages << { role: 'user', content: entry.trigger_content }

      # Group messages into alternating user/assistant
      messages = group_messages_with_alternation(initial_messages)

      # Ensure first message is user
      ensure_first_message_is_user(messages)

      # Ensure last message is user (Claude uses partial_assistant separately)
      ensure_last_message_is_user(messages)

      messages
    end

    # Group messages into proper user/assistant alternation
    # Combines consecutive same-role messages and merges time gaps into user content
    def group_messages_with_alternation(initial_messages)
      messages = []
      current_user_content = []

      initial_messages.each do |msg|
        case msg[:role]
        when 'time_gap'
          # Time gaps merge into current user accumulator
          if current_user_content.any?
            current_user_content[-1] = "#{current_user_content[-1]}\n\n#{msg[:content]}"
          else
            current_user_content << msg[:content]
          end
        when 'assistant'
          # Flush accumulated user content first
          if current_user_content.any?
            messages << { role: 'user', content: current_user_content.join("\n\n") }
            current_user_content = []
          end
          messages << { role: 'assistant', content: msg[:content] }
        else # user
          current_user_content << msg[:content]
        end
      end

      # Flush remaining user content
      if current_user_content.any?
        messages << { role: 'user', content: current_user_content.join("\n\n") }
      end

      # Combine consecutive same-role messages
      combine_consecutive_roles(messages)
    end

    # Combine consecutive messages with the same role
    def combine_consecutive_roles(messages)
      return messages if messages.size < 2

      i = 0
      while i < messages.size - 1
        if messages[i][:role] == messages[i + 1][:role]
          messages[i][:content] = "#{messages[i][:content]}\n\n#{messages[i + 1][:content]}"
          messages.delete_at(i + 1)
        else
          i += 1
        end
      end

      messages
    end

    # Ensure first message is user role
    def ensure_first_message_is_user(messages)
      return if messages.empty?
      return if messages[0][:role] == 'user'

      if messages.size > 1
        # Combine first two messages as user
        messages[0][:content] = "#{messages[0][:content]}\n\n#{messages[1][:content]}"
        messages[0][:role] = 'user'
        messages.delete_at(1)
      else
        messages[0][:role] = 'user'
      end
    end

    # Ensure last message is user role
    def ensure_last_message_is_user(messages)
      return if messages.empty?
      return if messages[-1][:role] == 'user'

      if messages.size > 1
        # Combine last two messages as user
        messages[-2][:content] = "#{messages[-2][:content]}\n\n#{messages[-1][:content]}"
        messages[-2][:role] = 'user'
        messages.pop
      else
        messages.append({ role: 'user', content: '(The scene continues...)' })
      end
    end

    # Build PC descriptions for people present in the room
    def build_pc_descriptions(npc_instance)
      room_chars = CharacterInstance
        .where(current_room_id: npc_instance.current_room_id, online: true)
        .exclude(id: npc_instance.id)
        .all

      return nil if room_chars.empty?

      room_chars.map do |ci|
        char = ci.character
        next unless char && !char.npc?

        desc = char.short_desc || char.full_name
        "#{char.full_name}: #{desc}"
      end.compact.join("\n")
    end

    # Generate emote and broadcast it
    # Uses proper user/assistant message alternation matching Python implementation
    def generate_and_broadcast_emote(npc_instance, entry)
      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character
      is_first = !npc_instance.animation_first_emote_done

      # Check for puppet mode - intercept and send to puppeteer instead of broadcasting
      if npc_instance.puppet_mode?
        return generate_puppet_suggestion(npc_instance, entry)
      end

      # Build system prompt (character, personality, guidelines)
      # This includes seed instruction if present
      system_prompt = build_system_prompt(npc_instance, entry)

      # Clear seed instruction after use (one-shot)
      if npc_instance.seed_mode?
        npc_instance.clear_seed_instruction!
      end

      # Build message history with user/assistant alternation
      messages = build_message_history(npc_instance, entry)

      # If no messages, add a minimal prompt
      if messages.empty?
        messages = [{ role: 'user', content: entry.trigger_content }]
      end

      # Select model based on whether this is first emote
      model = is_first ? archetype.effective_first_emote_model : archetype.effective_primary_model
      provider = NpcArchetype.provider_for_model(model)

      # Build options with system prompt and messages
      options = {
        temperature: 0.8,
        system_prompt: system_prompt,
        messages: messages
      }

      # Add partial assistant prefix for Claude models
      if NpcArchetype.claude_model?(model)
        options[:partial_assistant] = "#{character.forename}'s action: "
      end

      # Generate (prompt is ignored when messages are provided)
      result = LLM::Client.generate(
        prompt: '', # Ignored when options[:messages] is set
        model: model,
        provider: provider,
        options: options
      )

      unless result[:success]
        # Try fallbacks with same message structure
        result = try_fallback_models(archetype, system_prompt, messages, character.forename)
      end

      if result[:success] && result[:text]
        emote_text = clean_emote_text(result[:text], character.forename)
        broadcast_emote(npc_instance, emote_text)
        { success: true, emote: emote_text }
      else
        { success: false, error: result[:error] || 'Generation failed' }
      end
    end

    # Try fallback models if primary fails
    def try_fallback_models(archetype, system_prompt, messages, forename)
      archetype.fallback_models.each do |model|
        provider = NpcArchetype.provider_for_model(model)
        options = {
          temperature: 0.8,
          system_prompt: system_prompt,
          messages: messages
        }

        if NpcArchetype.claude_model?(model)
          options[:partial_assistant] = "#{forename}'s action: "
        end

        result = LLM::Client.generate(
          prompt: '',
          model: model,
          provider: provider,
          options: options
        )

        return result if result[:success]
      end

      { success: false, error: 'All fallback models failed' }
    end

    # Build the system prompt (character identity, personality, guidelines)
    # Context (lore, memories, relationships) is included here
    def build_system_prompt(npc_instance, entry)
      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character
      game_setting = GameSetting.get('world_type') || 'modern fantasy'

      # Get contextual information
      context = build_context(npc_instance, entry)

      # Build optional voice sections
      voice_sections = build_voice_sections(npc_instance, archetype)

      GamePrompts.get('npc_animation.system_prompt',
                       character_name: character.full_name,
                       game_setting: game_setting,
                       personality_prompt: archetype.effective_personality_prompt,
                       voice_sections: voice_sections,
                       forename: character.forename,
                       context: context,
                       seed_instruction: seed_instruction_prompt(npc_instance))
    end

    # Build optional voice configuration sections from archetype and instance data
    def build_voice_sections(npc_instance, archetype)
      sections = []

      sections << build_style_exemplar_section(npc_instance)
      sections << build_example_dialogue_section(archetype)
      sections << build_speech_pattern_section(archetype)
      sections << build_character_flaws_section(archetype)

      sections.compact.join("\n\n")
    end

    # Build style exemplar section from the NPC's first emote
    def build_style_exemplar_section(npc_instance)
      exemplar = npc_instance.style_exemplar
      return nil if StringHelper.blank?(exemplar)

      <<~SECTION.strip
        STYLE REFERENCE (match this tone and voice):
        #{exemplar}
      SECTION
    end

    # Build example dialogue section from archetype
    def build_example_dialogue_section(archetype)
      dialogue = archetype.effective_example_dialogue
      return nil unless dialogue

      <<~SECTION.strip
        EXAMPLE DIALOGUE (match this speech style):
        #{dialogue}
      SECTION
    end

    # Build speech patterns section from archetype quirks and vocabulary
    def build_speech_pattern_section(archetype)
      parts = []

      quirks = archetype.effective_speech_quirks
      parts << "SPEECH PATTERNS:\n#{quirks}" if quirks

      vocab = archetype.effective_vocabulary_notes
      parts << "VOCABULARY:\n#{vocab}" if vocab

      parts.empty? ? nil : parts.join("\n\n")
    end

    # Build character flaws section from archetype
    def build_character_flaws_section(archetype)
      flaws = archetype.effective_character_flaws
      return nil unless flaws

      <<~SECTION.strip
        YOUR BLIND SPOTS AND FLAWS (embody these naturally, don't announce them):
        #{flaws}
      SECTION
    end

    # Build seed instruction section if present
    def seed_instruction_prompt(npc_instance)
      return '' unless npc_instance.seed_mode? && npc_instance.puppet_instruction

      <<~INSTRUCTION

        SPECIAL INSTRUCTION FROM STORYTELLER:
        #{npc_instance.puppet_instruction}
        (Follow this instruction naturally in your next response)
      INSTRUCTION
    end

    # Generate suggestion for puppeted NPC and send to puppeteer
    # @param npc_instance [CharacterInstance] the puppeted NPC
    # @param entry [NpcAnimationQueue] the queue entry
    # @return [Hash] result with :success, :puppeted flag
    def generate_puppet_suggestion(npc_instance, entry)
      puppeteer = npc_instance.puppeteer
      unless puppeteer&.online
        # No puppeteer online - just skip the animation silently
        return { success: true, puppeted: true, emote: nil }
      end

      archetype = npc_instance.character.npc_archetype
      character = npc_instance.character
      is_first = !npc_instance.animation_first_emote_done

      # Build the same context we'd use for a normal emote
      system_prompt = build_system_prompt(npc_instance, entry)
      messages = build_message_history(npc_instance, entry)

      if messages.empty?
        messages = [{ role: 'user', content: entry.trigger_content }]
      end

      # Select model
      model = is_first ? archetype.effective_first_emote_model : archetype.effective_primary_model
      provider = NpcArchetype.provider_for_model(model)

      options = {
        temperature: 0.8,
        system_prompt: system_prompt,
        messages: messages
      }

      if NpcArchetype.claude_model?(model)
        options[:partial_assistant] = "#{character.forename}'s action: "
      end

      result = LLM::Client.generate(
        prompt: '',
        model: model,
        provider: provider,
        options: options
      )

      unless result[:success]
        result = try_fallback_models(archetype, system_prompt, messages, character.forename)
      end

      if result[:success] && result[:text]
        suggestion = clean_emote_text(result[:text], character.forename)

        # Store the suggestion on the NPC
        npc_instance.set_puppet_suggestion!(suggestion)

        # Send to puppeteer
        send_suggestion_to_puppeteer(puppeteer, npc_instance, suggestion, entry)

        { success: true, puppeted: true, emote: suggestion }
      else
        { success: false, error: result[:error] || 'Suggestion generation failed' }
      end
    end

    # Send a puppet suggestion to the staff member
    def send_suggestion_to_puppeteer(puppeteer, npc_instance, suggestion, entry)
      npc_name = npc_instance.character.forename
      npc_full_name = npc_instance.full_name
      room_name = npc_instance.current_room&.name || 'unknown location'

      # Build trigger context
      trigger_source = entry.trigger_source_id ? CharacterInstance[entry.trigger_source_id] : nil
      trigger_text = entry.trigger_content.to_s
      trigger_text = trigger_text.length > 50 ? "#{trigger_text[0..47]}..." : trigger_text

      trigger_context = if trigger_source
                          "#{trigger_source.full_name}: #{trigger_text}"
                        else
                          trigger_text
                        end

      # Format as inline message
      message = {
        content: "[PUPPET] #{npc_full_name}: #{suggestion}",
        html: <<~HTML
          <div class='puppet-suggestion'>
            <div class='puppet-header'>
              <span class='puppet-label'>[PUPPET SUGGESTION]</span>
              <span class='puppet-npc-name'>#{npc_full_name}</span>
              <span class='puppet-location'>(#{room_name})</span>
            </div>
            <div class='puppet-trigger'>Triggered by: #{trigger_context}</div>
            <div class='puppet-suggestion-text'>#{suggestion}</div>
            <div class='puppet-hint'>Use: pemote #{npc_name} = &lt;text&gt;</div>
          </div>
        HTML
      }

      BroadcastService.to_character(
        puppeteer,
        message,
        type: :puppet_suggestion,
        sender_instance: npc_instance
      )
    end

    # Clean up the generated emote text
    def clean_emote_text(text, forename)
      # Remove any partial prefix from Claude
      cleaned = text.strip.sub(/^#{Regexp.escape(forename)}'s Action:\s*/i, '')

      # Ensure it starts with character name
      unless cleaned.downcase.start_with?(forename.downcase)
        cleaned = "#{forename} #{cleaned}"
      end

      cleaned
    end

    # Broadcast the emote to the room
    def broadcast_emote(npc_instance, emote_text)
      BroadcastService.to_room(
        npc_instance.current_room_id,
        { content: emote_text, html: emote_text },
        type: :emote,
        sender_instance: npc_instance
      )
    end

    # Update animation tracking on the instance
    # Captures style exemplar from first emote for voice anchoring
    def update_animation_tracking(npc_instance, emote_text = nil)
      updates = {
        last_animation_at: Time.now,
        animation_emote_count: (npc_instance.animation_emote_count || 0) + 1,
        animation_first_emote_done: true
      }

      # Capture first emote as style exemplar if not already set
      if !npc_instance.animation_first_emote_done &&
         StringHelper.blank?(npc_instance.style_exemplar) &&
         emote_text && !emote_text.strip.empty?
        updates[:style_exemplar] = emote_text
      end

      npc_instance.update(updates)
    end

    # ============================================
    # Enhanced Context Methods (Memory/Relationships/Lore)
    # ============================================

    # Fetch relevant lore from helpfiles using semantic search
    # @return [String, nil] formatted lore context
    def fetch_lore_context(query)
      return nil if query.nil? || query.strip.empty?

      Helpfile.lore_context_for(query, limit: 2)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch lore: #{e.message}"
      nil
    end

    # Fetch relevant memories for the NPC using semantic search
    # @return [String, nil] formatted memory context
    def fetch_memory_context(npc, query)
      return nil unless npc && query

      memories = NpcMemoryService.retrieve_relevant(
        npc: npc,
        query: query,
        limit: 3,
        include_abstractions: true
      )

      return nil if memories.empty?

      NpcMemoryService.format_for_context(memories)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch memories: #{e.message}"
      nil
    end

    # Fetch relevant world memories (witnessed or heard about)
    # @param npc [Character] The NPC character
    # @param query [String] Trigger content for semantic search
    # @param room [Room] NPC's current room
    # @return [String, nil] formatted world memory context
    def fetch_world_memory_context(npc, query, room)
      return nil unless npc

      memories = WorldMemoryService.retrieve_for_npc(
        npc: npc,
        query: query,
        room: room,
        limit: 3
      )

      return nil if memories.empty?

      WorldMemoryService.format_for_npc_context(memories, npc: npc)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch world memories: #{e.message}"
      nil
    end

    # Fetch narrative thread context for NPC awareness
    # @param npc [Character] The NPC character
    # @param room [Room] NPC's current room
    # @return [String, nil] formatted narrative thread context
    def fetch_narrative_context(npc, room)
      return nil unless npc && defined?(WorldMemoryService)

      threads = WorldMemoryService.retrieve_thread_context_for_npc(npc: npc, room: room, limit: 3)
      return nil if threads.empty?

      WorldMemoryService.format_thread_context_for_npc(threads)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch narrative context: #{e.message}"
      nil
    end

    # Fetch relevant clues that the NPC knows about
    # Only returns clues if talking to a PC
    # @param npc [Character] The NPC character
    # @param entry [NpcAnimationQueue] Queue entry with trigger info
    # @return [String, nil] formatted clue context
    def fetch_clue_context(npc, entry)
      return nil unless npc && entry.trigger_source_id

      # Only provide clues when talking to a PC
      source_instance = CharacterInstance[entry.trigger_source_id]
      return nil unless source_instance&.character && !source_instance.character.npc?

      pc = source_instance.character
      arranged_scene_id = arranged_scene_id_for(
        npc_character_id: npc.id,
        trigger_source_id: source_instance.id
      )

      clue_info = ClueService.relevant_clues_for(
        npc: npc,
        query: entry.trigger_content,
        pc: pc,
        limit: 2,
        arranged_scene_id: arranged_scene_id
      )

      return nil if clue_info.empty?

      ClueService.format_for_context(clue_info)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch clues: #{e.message}"
      nil
    end

    # Fetch reputation context for PCs in the room based on NPC's knowledge tier
    # @param npc_instance [CharacterInstance]
    # @return [String, nil]
    def fetch_reputation_context(npc_instance)
      npc = npc_instance.character
      return nil unless npc

      # Get PCs in the room
      room_pcs = CharacterInstance
        .where(current_room_id: npc_instance.current_room_id, online: true)
        .exclude(id: npc_instance.id)
        .all
        .select { |ci| ci.character && !ci.character.npc? }

      return nil if room_pcs.empty?

      reputation_entries = []

      room_pcs.first(5).each do |pc_instance|
        pc = pc_instance.character
        next unless pc

        # Get NPC's relationship with this PC (or create with defaults)
        relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
        knowledge_tier = relationship.knowledge_tier || 1

        # Get reputation based on knowledge tier
        reputation = ReputationService.reputation_for(pc, knowledge_tier: knowledge_tier)

        # Skip if no reputation or "nothing notable"
        next if reputation.nil? || reputation.strip.empty?

        # Format entry with tier description
        tier_label = relationship.knowledge_label
        reputation_entries << "#{pc.full_name} (#{tier_label}):\n#{reputation}"
      end

      return nil if reputation_entries.empty?

      reputation_entries.join("\n\n")
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch reputation context: #{e.message}"
      nil
    end

    def fetch_relationship_context(npc_instance, entry)
      npc = npc_instance.character
      return nil unless npc

      relationships = []

      # Get relationship with trigger source if they're a PC
      if entry.trigger_source_id
        source_instance = CharacterInstance[entry.trigger_source_id]
        if source_instance && source_instance.character && !source_instance.character.npc?
          rel = NpcRelationship.find_or_create_for(
            npc: npc,
            pc: source_instance.character
          )
          relationships << rel.to_context_string if rel
        end
      end

      # Also get relationships with other PCs in the room
      room_pcs = CharacterInstance
        .where(current_room_id: npc_instance.current_room_id, online: true)
        .exclude(id: npc_instance.id)
        .all
        .select { |ci| ci.character && !ci.character.npc? }

      room_pcs.first(3).each do |pc_instance|
        rel = NpcRelationship.for_npc(npc).where(pc_character_id: pc_instance.character.id).first
        relationships << rel.to_context_string if rel
      end

      return nil if relationships.empty?

      relationships.uniq.join("\n")
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to fetch relationships: #{e.message}"
      nil
    end

    # Post-animation: store memory and update relationship
    def post_animation_update(npc_instance, entry, emote_text)
      npc = npc_instance.character
      return unless npc

      # Store memory of this interaction
      store_interaction_memory(npc, entry, emote_text)

      # Update relationship with trigger source
      update_relationship_from_interaction(npc, entry, emote_text)
    rescue StandardError => e
      warn "[NpcAnimationHandler] Post-animation update failed: #{e.message}"
    end

    # Store a memory of this interaction
    def store_interaction_memory(npc, entry, emote_text)
      # Find the source PC
      source_pc = nil
      if entry.trigger_source_id
        source_instance = CharacterInstance[entry.trigger_source_id]
        source_pc = source_instance&.character if source_instance&.character && !source_instance.character.npc?
      end

      # Create a concise memory summary
      content = "Interaction: #{entry.trigger_content} → Responded: #{emote_text}"
      if content.length > 300
        content = content[0..297] + '...'
      end

      NpcMemoryService.store_memory(
        npc: npc,
        content: content,
        about_character: source_pc,
        importance: 4,
        memory_type: 'interaction'
      )
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to store memory: #{e.message}"
    end

    # Update relationship based on the interaction using LLM evaluation (async)
    def update_relationship_from_interaction(npc, entry, emote_text)
      return unless entry.trigger_source_id

      source_instance = CharacterInstance[entry.trigger_source_id]
      return unless source_instance&.character && !source_instance.character.npc?

      pc = source_instance.character

      NpcRelationshipUpdateJob.perform_async(
        npc.id,
        pc.id,
        entry.trigger_content.to_s,
        emote_text.to_s
      )
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to start relationship update: #{e.message}"
    end

    # Evaluate interaction deltas via LLM
    # @return [Hash] { sentiment_delta:, trust_delta:, notable_event: }
    def evaluate_interaction_deltas(npc_name:, personality:, behavior_pattern:, trigger_content:, emote_response:)
      prompt = GamePrompts.get(
        'npc_animation.evaluate_interaction',
        npc_name: npc_name,
        personality: personality,
        behavior_pattern: behavior_pattern,
        trigger_content: trigger_content,
        emote_response: emote_response
      )

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: { temperature: 0.3, json_mode: true }
      )

      if result[:success] && result[:text]
        clean_text = result[:text].to_s.strip
          .gsub(/\A```(?:json)?\s*/, '')
          .gsub(/\s*```\z/, '')
        parsed = JSON.parse(clean_text)
        {
          sentiment_delta: clamp_delta(parsed['sentiment_delta']&.to_f || 0.0, -0.2, 0.2),
          trust_delta: clamp_delta(parsed['trust_delta']&.to_f || 0.0, -0.1, 0.1),
          notable_event: parsed['notable_event']
        }
      else
        { sentiment_delta: 0.0, trust_delta: 0.0, notable_event: nil }
      end
    rescue JSON::ParserError => e
      warn "[NpcAnimationHandler] Failed to parse interaction eval JSON: #{e.message}"
      { sentiment_delta: 0.0, trust_delta: 0.0, notable_event: nil }
    rescue StandardError => e
      warn "[NpcAnimationHandler] Interaction eval failed: #{e.message}"
      { sentiment_delta: 0.0, trust_delta: 0.0, notable_event: nil }
    end

    # Clamp a delta value to a range
    def clamp_delta(value, min, max)
      [[value, min].max, max].min
    end

    def find_matching_puppet_queue_entry(npc_instance:, emote_text:, suggestion_text: nil)
      query = NpcAnimationQueue.where(character_instance_id: npc_instance.id, status: 'complete')
                               .where { processed_at > Time.now - 3600 }

      if StringHelper.present?(suggestion_text)
        exact = query.where(llm_response: suggestion_text).order(Sequel.desc(:processed_at)).first
        return exact if exact
      end

      query.where(llm_response: emote_text).order(Sequel.desc(:processed_at)).first
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to find matching queue entry: #{e.message}"
      nil
    end

    # Resolve scene context so scene-scoped triggers/clues activate correctly.
    def arranged_scene_id_for(npc_character_id:, trigger_source_id:)
      source_instance = trigger_source_id ? CharacterInstance[trigger_source_id] : nil
      if source_instance
        scene = ArrangedScene.active_for(source_instance)
        return scene.id if scene && scene.npc_character_id == npc_character_id

        # If we know who triggered this, don't fall back to an unrelated active scene.
        return nil
      end

      npc_scene = ArrangedScene.where(npc_character_id: npc_character_id, status: 'active').first
      npc_scene&.id
    rescue StandardError => e
      warn "[NpcAnimationHandler] Failed to resolve arranged scene context: #{e.message}"
      nil
    end

  end
end
