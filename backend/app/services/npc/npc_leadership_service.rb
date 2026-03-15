# frozen_string_literal: true

# NpcLeadershipService - Handles NPC lead/summon/query requests with LLM decisions
#
# This service manages PC-NPC following relationships:
# - Lead requests: PC asks NPC to follow them (LLM decides)
# - Summon requests: PC sends message to summon NPC (LLM decides)
# - Leave checks: Periodic check if following NPC should stop following
# - Staff queries: Direct questions to any NPC
#
# Flag hierarchy: Character override → Archetype default
# Cooldowns: 1 hour after rejection per PC/NPC pair
#
module NpcLeadershipService
  class << self
    # ============================================
    # Flag Checks
    # ============================================

    # Check if an NPC can be led by PCs
    # @param npc_character [Character] the NPC character
    # @return [Boolean]
    def can_be_led?(npc_character)
      npc_character&.leadable? || false
    end

    # Check if an NPC can be summoned by PCs
    # @param npc_character [Character] the NPC character
    # @return [Boolean]
    def can_be_summoned?(npc_character)
      npc_character&.summonable? || false
    end

    # ============================================
    # Cooldown Checks
    # ============================================

    # Check if PC is on lead cooldown for this NPC
    # @param npc [Character] NPC character
    # @param pc [Character] PC character
    # @return [Boolean]
    def on_lead_cooldown?(npc:, pc:)
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      relationship.on_lead_cooldown?
    end

    # Check if PC is on summon cooldown for this NPC
    # @param npc [Character] NPC character
    # @param pc [Character] PC character
    # @return [Boolean]
    def on_summon_cooldown?(npc:, pc:)
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      relationship.on_summon_cooldown?
    end

    # Get remaining cooldown time for lead
    # @param npc [Character] NPC character
    # @param pc [Character] PC character
    # @return [Integer] seconds remaining
    def lead_cooldown_remaining(npc:, pc:)
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      relationship.lead_cooldown_remaining
    end

    # Get remaining cooldown time for summon
    # @param npc [Character] NPC character
    # @param pc [Character] PC character
    # @return [Integer] seconds remaining
    def summon_cooldown_remaining(npc:, pc:)
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)
      relationship.summon_cooldown_remaining
    end

    # ============================================
    # Lead Request
    # ============================================

    # Request an NPC to follow a PC - runs LLM decision async
    # @param npc_instance [CharacterInstance] the NPC to lead
    # @param pc_instance [CharacterInstance] the PC requesting
    # @return [Hash] { success:, message:, async: true }
    def request_lead(npc_instance:, pc_instance:)
      Thread.new do
        process_lead_request(npc_instance: npc_instance, pc_instance: pc_instance)
      rescue StandardError => e
        warn "[NpcLeadershipService] Lead request error: #{e.message}"
      end

      { success: true, message: 'Your request is being considered...', async: true }
    end

    # ============================================
    # Summon Request
    # ============================================

    # Request an NPC to come to a PC - runs LLM decision async
    # @param npc_instance [CharacterInstance] the NPC to summon
    # @param pc_instance [CharacterInstance] the PC requesting
    # @param message [String] the summon message from PC
    # @return [Hash] { success:, message:, async: true }
    def request_summon(npc_instance:, pc_instance:, message:)
      Thread.new do
        process_summon_request(
          npc_instance: npc_instance,
          pc_instance: pc_instance,
          message: message
        )
      rescue StandardError => e
        warn "[NpcLeadershipService] Summon request error: #{e.message}"
      end

      { success: true, message: 'Your message is being delivered...', async: true }
    end

    # ============================================
    # Leave Check
    # ============================================

    # Check if a following NPC should leave their leader
    # Called from NpcAnimationHandler after emotes
    # @param npc_instance [CharacterInstance] the following NPC
    # @return [Hash] { should_leave:, reason: }
    def check_and_handle_leave(npc_instance:)
      return { should_leave: false } unless npc_instance.following_id

      leader = CharacterInstance[npc_instance.following_id]

      # Auto-leave conditions (no LLM needed)
      if leader.nil? || !leader.online
        npc_leave_leader(npc_instance: npc_instance, reason: 'leader_offline')
        return { should_leave: true, reason: 'leader_offline' }
      end

      # Check if leader is in a different room AND NPC has scheduled location elsewhere
      if leader.current_room_id != npc_instance.current_room_id
        schedule = npc_instance.character.npc_schedules_dataset
                               .where { (start_hour <= Time.now.hour) & (end_hour > Time.now.hour) }
                               .first
        if schedule && schedule.room_id != npc_instance.current_room_id
          npc_leave_leader(npc_instance: npc_instance, reason: 'leader_left_and_schedule_calls')
          return { should_leave: true, reason: 'leader_left_and_schedule_calls' }
        end
      end

      { should_leave: false }
    end

    # Make NPC stop following and optionally return to schedule
    # @param npc_instance [CharacterInstance] the NPC
    # @param reason [String] why leaving
    # @return [Hash] result
    def npc_leave_leader(npc_instance:, reason:)
      leader = CharacterInstance[npc_instance.following_id]
      npc_name = npc_instance.character.full_name
      leader_name = leader&.character&.full_name || 'their leader'

      # Clear following
      npc_instance.update(following_id: nil)

      # Emit departure
      departure_msg = case reason
                      when 'leader_offline'
                        "#{npc_name} notices #{leader_name} is gone and stops following."
                      when 'leader_left_and_schedule_calls'
                        "#{npc_name} has somewhere else to be and takes their leave."
                      else
                        "#{npc_name} stops following #{leader_name}."
                      end

      BroadcastService.to_room(
        npc_instance.current_room_id,
        departure_msg,
        type: :narrative,
        sender_instance: npc_instance
      )

      # Log NPC departure to character stories (use RpLoggingService directly
      # to avoid re-triggering NPC/pet animation side effects from NPC content)
      RpLoggingService.log_to_room(
        npc_instance.current_room_id, departure_msg,
        sender: npc_instance, type: 'narrative'
      )

      # Return to scheduled location if applicable
      return_to_schedule(npc_instance)

      { success: true, reason: reason }
    end

    # ============================================
    # Staff Query
    # ============================================

    # Query any NPC with a question (staff only, sync)
    # @param npc_instance [CharacterInstance] the NPC to query
    # @param question [String] the question to ask
    # @return [Hash] { success:, response: }
    def query_npc(npc_instance:, question:)
      npc = npc_instance.character
      archetype = npc.npc_archetype

      system_prompt = build_query_system_prompt(npc_instance)
      prompt = "Staff query: #{question}"

      model = archetype&.effective_primary_model || 'gemini-3-flash-preview'
      provider = NpcArchetype.provider_for_model(model)

      result = LLM::Client.generate(
        prompt: prompt,
        model: model,
        provider: provider,
        options: {
          max_tokens: 500,
          temperature: 0.7,
          system_prompt: system_prompt
        }
      )

      if result[:success]
        { success: true, response: result[:text] }
      else
        { success: false, error: result[:error] || 'Query failed' }
      end
    rescue StandardError => e
      warn "[NpcLeadershipService] Query error: #{e.message}"
      { success: false, error: e.message }
    end

    # ============================================
    # NPC Finding
    # ============================================

    # Find an NPC in the same room as the PC
    # @param pc_instance [CharacterInstance] the PC
    # @param name [String] NPC name to search
    # @return [CharacterInstance, nil]
    def find_npc_in_room(pc_instance:, name:)
      candidates = CharacterInstance.where(
        current_room_id: pc_instance.current_room_id,
        online: true
      ).eager(:character).all

      npcs = candidates.select { |ci| ci.character.npc? }

      resolve_by_name(npcs, name)
    end

    # Find an NPC within summon range of the PC
    # @param pc_instance [CharacterInstance] the PC
    # @param name [String] NPC name to search
    # @return [CharacterInstance, nil]
    def find_npc_in_summon_range(pc_instance:, name:)
      # Get all online NPCs
      candidates = CharacterInstance.where(online: true).eager(:character).all
      npcs = candidates.select { |ci| ci.character.npc? }

      # Filter by summon range
      room = pc_instance.current_room
      zone_id = room&.location&.zone_id

      npcs_in_range = npcs.select do |npc|
        range = npc.character.summon_range
        case range
        when 'room'
          npc.current_room_id == pc_instance.current_room_id
        when 'zone', 'area'
          npc_room = npc.current_room
          npc_room&.location&.zone_id == zone_id
        when 'world'
          true
        else
          npc_room = npc.current_room
          npc_room&.location&.zone_id == zone_id
        end
      end

      resolve_by_name(npcs_in_range, name)
    end

    private

    # ============================================
    # Lead Request Processing
    # ============================================

    def process_lead_request(npc_instance:, pc_instance:)
      npc = npc_instance.character
      pc = pc_instance.character
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)

      # Build context and prompt
      context = build_leadership_context(npc_instance: npc_instance, pc_instance: pc_instance)
      prompt = build_lead_prompt(npc_instance: npc_instance, pc_instance: pc_instance, context: context)

      # Get LLM decision
      decision = generate_npc_decision(npc_instance: npc_instance, prompt: prompt, decision_type: 'lead')

      if decision[:accept]
        # NPC agrees to follow
        npc_instance.update(following_id: pc_instance.id)

        emit_accept_lead(npc_instance: npc_instance, pc_instance: pc_instance, response: decision[:response])

        # Update relationship positively
        relationship.record_interaction(sentiment_delta: 0.05, trust_delta: 0.02)
      else
        # NPC refuses
        relationship.record_lead_rejection!

        emit_reject_lead(npc_instance: npc_instance, pc_instance: pc_instance, response: decision[:response])

        # Update relationship slightly negatively if low trust
        if relationship.trust < 0.4
          relationship.record_interaction(sentiment_delta: -0.02)
        end
      end
    end

    # ============================================
    # Summon Request Processing
    # ============================================

    def process_summon_request(npc_instance:, pc_instance:, message:)
      npc = npc_instance.character
      pc = pc_instance.character
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)

      # Build context and prompt
      context = build_leadership_context(npc_instance: npc_instance, pc_instance: pc_instance)
      prompt = build_summon_prompt(
        npc_instance: npc_instance,
        pc_instance: pc_instance,
        message: message,
        context: context
      )

      # Get LLM decision
      decision = generate_npc_decision(npc_instance: npc_instance, prompt: prompt, decision_type: 'summon')

      if decision[:accept]
        # NPC agrees to come
        emit_accept_summon(npc_instance: npc_instance, pc_instance: pc_instance, response: decision[:response])

        # Move NPC to PC's room
        move_npc_to_pc(npc_instance: npc_instance, pc_instance: pc_instance)

        # Update relationship positively
        relationship.record_interaction(sentiment_delta: 0.05, trust_delta: 0.02)
      else
        # NPC refuses
        relationship.record_summon_rejection!

        emit_reject_summon(npc_instance: npc_instance, pc_instance: pc_instance, response: decision[:response])
      end
    end

    # ============================================
    # LLM Decision Making
    # ============================================

    def generate_npc_decision(npc_instance:, prompt:, decision_type:)
      archetype = npc_instance.character.npc_archetype
      model = archetype&.effective_primary_model || 'gemini-3-flash-preview'
      provider = NpcArchetype.provider_for_model(model)

      system_prompt = build_decision_system_prompt(npc_instance, decision_type)

      result = LLM::Client.generate(
        prompt: prompt,
        model: model,
        provider: provider,
        options: {
          max_tokens: 300,
          temperature: 0.7,
          system_prompt: system_prompt
        }
      )

      unless result[:success]
        # Default to rejection on failure
        return { accept: false, response: 'seems uncertain and hesitates.' }
      end

      parse_decision_response(result[:text])
    end

    def build_decision_system_prompt(npc_instance, decision_type)
      npc = npc_instance.character
      archetype = npc.npc_archetype
      game_setting = GameSetting.get('world_type') || 'modern fantasy'

      action = decision_type == 'lead' ? 'follow them' : 'go to them'

      GamePrompts.get('npc_leadership.decision_system',
                      npc_name: npc.full_name,
                      game_setting: game_setting,
                      personality_prompt: archetype&.effective_personality_prompt || 'You are a typical inhabitant of this world.',
                      action: action,
                      npc_forename: npc.forename)
    end

    def parse_decision_response(text)
      lines = text.strip.split("\n", 2)
      first_line = lines.first&.strip&.upcase || ''

      accept = first_line.include?('ACCEPT')
      response = lines.last&.strip || (accept ? 'nods in agreement.' : 'shakes their head.')

      # Clean up response
      response = response.gsub(/^(ACCEPT|REJECT)\s*/i, '').strip
      response = 'considers the request.' if response.empty?

      { accept: accept, response: response }
    end

    # ============================================
    # Context Building
    # ============================================

    def build_leadership_context(npc_instance:, pc_instance:)
      npc = npc_instance.character
      pc = pc_instance.character
      relationship = NpcRelationship.find_or_create_for(npc: npc, pc: pc)

      parts = []

      # Relationship info
      parts << "RELATIONSHIP WITH #{pc.full_name}:"
      parts << relationship.to_context_string
      parts << "Interactions: #{relationship.interaction_count}"
      parts << "Knowledge: #{relationship.knowledge_tier_descriptor}"

      # Current location
      room = npc_instance.current_room
      parts << "\nCURRENT LOCATION: #{room&.name || 'Unknown'}"
      parts << room.description if room&.description && room.description.length < 200

      # Schedule info
      schedule = npc.npc_schedules_dataset
                    .where { (start_hour <= Time.now.hour) & (end_hour > Time.now.hour) }
                    .first
      if schedule
        scheduled_room = Room[schedule.room_id]
        if scheduled_room && scheduled_room.id != npc_instance.current_room_id
          parts << "\nSCHEDULE: Should be at #{scheduled_room.name} right now"
        elsif schedule.activity_description
          parts << "\nSCHEDULE: Currently #{schedule.activity_description}"
        end
      end

      # Already following?
      if npc_instance.following_id
        leader = CharacterInstance[npc_instance.following_id]
        parts << "\nCURRENTLY FOLLOWING: #{leader&.character&.full_name || 'someone'}"
      end

      parts.join("\n")
    end

    def build_lead_prompt(npc_instance:, pc_instance:, context:)
      GamePrompts.get('npc_leadership.lead_request',
                       context: context,
                       pc_name: pc_instance.character.full_name,
                       npc_name: npc_instance.character.full_name)
    end

    def build_summon_prompt(npc_instance:, pc_instance:, message:, context:)
      GamePrompts.get('npc_leadership.summon_request',
                       context: context,
                       pc_name: pc_instance.character.full_name,
                       npc_name: npc_instance.character.full_name,
                       room_name: pc_instance.current_room&.name || 'another location',
                       message: message)
    end

    def build_query_system_prompt(npc_instance)
      npc = npc_instance.character
      archetype = npc.npc_archetype
      game_setting = GameSetting.get('world_type') || 'modern fantasy'
      room = npc_instance.current_room

      GamePrompts.get('npc_leadership.query_system',
                      npc_name: npc.full_name,
                      game_setting: game_setting,
                      personality_prompt: archetype&.effective_personality_prompt || 'You are a typical inhabitant of this world.',
                      room_name: room&.name || 'Unknown',
                      current_activity: npc_instance.roomtitle || 'nothing in particular')
    end

    # ============================================
    # Emits and Movement
    # ============================================

    def emit_accept_lead(npc_instance:, pc_instance:, response:)
      emit_npc_lead_response(npc_instance: npc_instance, pc_instance: pc_instance, response: response)
    end

    def emit_reject_lead(npc_instance:, pc_instance:, response:)
      emit_npc_lead_response(npc_instance: npc_instance, pc_instance: pc_instance, response: response)
    end

    # Broadcast an NPC's lead accept/reject emote to the room and log it.
    def emit_npc_lead_response(npc_instance:, pc_instance:, response:)
      npc_name = npc_instance.character.full_name

      full_response = if response.downcase.start_with?(npc_instance.character.forename.downcase)
                        response
                      else
                        "#{npc_name} #{response}"
                      end

      BroadcastService.to_room(
        npc_instance.current_room_id,
        full_response,
        type: :emote,
        sender_instance: npc_instance
      )

      # Log to character stories (use RpLoggingService directly
      # to avoid re-triggering NPC/pet animation from NPC content)
      RpLoggingService.log_to_room(
        npc_instance.current_room_id, full_response,
        sender: npc_instance, type: 'emote'
      )
    end

    def emit_accept_summon(npc_instance:, pc_instance:, response:)
      npc_name = npc_instance.character.full_name

      full_response = if response.downcase.start_with?(npc_instance.character.forename.downcase)
                        response
                      else
                        "#{npc_name} #{response}"
                      end

      # Emit departure at NPC's current location
      BroadcastService.to_room(
        npc_instance.current_room_id,
        full_response,
        type: :emote,
        sender_instance: npc_instance
      )

      # Log NPC accept summon to character stories (use RpLoggingService directly
      # to avoid re-triggering NPC/pet animation from NPC content)
      RpLoggingService.log_to_room(
        npc_instance.current_room_id, full_response,
        sender: npc_instance, type: 'emote'
      )
    end

    def emit_reject_summon(npc_instance:, pc_instance:, response:)
      npc_name = npc_instance.character.full_name
      pc_name = pc_instance.character.full_name

      full_response = if response.downcase.start_with?(npc_instance.character.forename.downcase)
                        response
                      else
                        "#{npc_name} #{response}"
                      end

      # Send rejection message to the PC
      BroadcastService.to_character(
        pc_instance,
        "You sense that #{npc_name} won't be coming. (#{full_response})",
        type: :narrative
      )

      # Log NPC reject summon to character story
      RpLoggingService.log_to_character(
        pc_instance,
        "You sense that #{npc_name} won't be coming. (#{full_response})",
        sender: npc_instance, type: 'narrative'
      )
    end

    def move_npc_to_pc(npc_instance:, pc_instance:)
      destination = pc_instance.current_room
      return unless destination

      # Use MovementService if available
      if defined?(MovementService) && MovementService.respond_to?(:start_movement)
        MovementService.start_movement(
          npc_instance,
          target: destination,
          adverb: 'walk'
        )
      else
        # Direct teleport as fallback
        npc_instance.teleport_to_room!(destination)

        # Announce arrival
        npc_name = npc_instance.character.full_name
        BroadcastService.to_room(
          destination.id,
          "#{npc_name} arrives.",
          type: :narrative,
          sender_instance: npc_instance
        )

        # Log NPC arrival to character stories (use RpLoggingService directly
        # to avoid re-triggering NPC/pet animation from NPC content)
        RpLoggingService.log_to_room(
          destination.id, "#{npc_name} arrives.",
          sender: npc_instance, type: 'narrative'
        )
      end
    end

    def return_to_schedule(npc_instance)
      npc = npc_instance.character

      schedule = npc.npc_schedules_dataset
                    .where { (start_hour <= Time.now.hour) & (end_hour > Time.now.hour) }
                    .first

      return unless schedule

      destination = Room[schedule.room_id]
      return unless destination && destination.id != npc_instance.current_room_id

      # Move NPC back to scheduled location
      if defined?(MovementService) && MovementService.respond_to?(:start_movement)
        MovementService.start_movement(
          npc_instance,
          target: destination,
          adverb: 'walk'
        )
      else
        npc_instance.teleport_to_room!(destination)
      end
    end

    # ============================================
    # Name Resolution
    # ============================================

    def resolve_by_name(npcs, name)
      return nil if npcs.empty? || name.nil? || name.strip.empty?

      name_lower = name.downcase.strip

      # Exact match on forename
      exact = npcs.find { |npc| npc.character.forename&.downcase == name_lower }
      return exact if exact

      # Exact match on full name
      exact_full = npcs.find { |npc| npc.character.full_name&.downcase == name_lower }
      return exact_full if exact_full

      # Partial match on forename
      partial = npcs.find { |npc| npc.character.forename&.downcase&.start_with?(name_lower) }
      return partial if partial

      # Partial match on full name
      partial_full = npcs.find { |npc| npc.character.full_name&.downcase&.include?(name_lower) }
      partial_full
    end
  end
end
