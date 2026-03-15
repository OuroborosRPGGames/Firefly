# frozen_string_literal: true

module AutoGm
  # AutoGmInciteService deploys the inciting incident to start the adventure.
  #
  # This service:
  # - Broadcasts the inciting narrative to all participants
  # - Spawns any NPCs involved in the incident
  # - Sets up initial world state
  # - Transitions the session to 'running' status
  #
  class AutoGmInciteService
    extend AutoGm::AutoGmFormatHelper
    extend AutoGm::AutoGmArchetypeConcern

    class << self
      # Deploy the inciting incident for a session
      # @param session [AutoGmSession] the session to incite
      # @return [Hash] { success:, action:, error: }
      def deploy(session)
        sketch = session.sketch
        return { success: false, error: 'No sketch available' } unless sketch
        return { success: false, error: 'No inciting incident in sketch' } unless sketch['inciting_incident']

        incident = sketch['inciting_incident']

        # Create the inciting action record
        action = create_incite_action(session, incident)

        # Broadcast the inciting narrative
        broadcast_incident(session, incident)

        # Mark the inciting action as completed
        action.complete!

        # Spawn any NPCs for stage 0 (the inciting stage)
        spawned_npcs = spawn_initial_npcs(session)

        # Initialize world state
        initialize_world_state(session, incident)

        # Start combat immediately for attack incidents with immediate threat.
        start_incident_combat(session, incident, spawned_npcs)

        { success: true, action: action }
      rescue StandardError => e
        { success: false, error: "Incite error: #{e.message}" }
      end

      # Generate inciting narrative if not provided
      # @param session [AutoGmSession] the session
      # @param context [Hash] context data
      # @return [String] generated narrative
      def generate_inciting_narrative(session, context)
        sketch = session.sketch
        incident = sketch['inciting_incident'] || {}

        # Build a prompt to generate the inciting narrative
        prompt = build_narrative_prompt(session, incident, context)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: 'google_gemini',
          model: 'gemini-3-flash-preview',
          options: { max_tokens: 500, temperature: 0.8 }
        )

        result[:success] ? result[:text] : incident['description'] || 'The adventure begins...'
      end

      private

      # Create the action record for the inciting incident
      # @param session [AutoGmSession] the session
      # @param incident [Hash] the incident data
      # @return [AutoGmAction] the created action
      def create_incite_action(session, incident)
        AutoGmAction.create_emit(
          session,
          build_incite_text(session, incident),
          reasoning: 'Deploying inciting incident to start the adventure'
        )
      end

      # Build the inciting text from the incident data
      # @param session [AutoGmSession] the session
      # @param incident [Hash] the incident data
      # @return [String] formatted text
      def build_incite_text(session, incident)
        parts = []

        # Add atmospheric opening based on mood
        mood = session.sketch.dig('setting', 'mood')
        parts << mood_prefix(mood) if mood

        # Add the incident description
        parts << incident['description'] if incident['description']

        # Add urgency cue if immediate threat
        if incident['immediate_threat']
          parts << urgency_suffix(incident['type'])
        end

        parts.join(' ')
      end

      # Get atmospheric prefix based on mood
      # @param mood [String] the mood
      # @return [String] prefix text
      def mood_prefix(mood)
        case mood
        when 'tense'
          'A palpable tension fills the air.'
        when 'mysterious'
          'Something strange stirs in the shadows.'
        when 'urgent'
          'Without warning,'
        when 'hopeful'
          'A glimmer of opportunity presents itself.'
        when 'dark'
          'An ominous presence makes itself known.'
        when 'chaotic'
          'Chaos erupts suddenly!'
        else
          ''
        end
      end

      # Get urgency suffix based on incident type
      # @param incident_type [String] the incident type
      # @return [String] suffix text
      def urgency_suffix(incident_type)
        case incident_type
        when 'attack'
          'There is no time to waste - act now!'
        when 'arrival'
          'Something demands your immediate attention.'
        when 'discovery'
          'What will you do with this knowledge?'
        when 'distress'
          'Someone needs help immediately!'
        when 'environmental'
          'The situation is deteriorating rapidly.'
        else
          'What will you do?'
        end
      end

      # Broadcast the incident to all participants
      # @param session [AutoGmSession] the session
      # @param incident [Hash] the incident data
      def broadcast_incident(session, incident)
        room_id = session.current_room_id || session.starting_room_id
        message = build_incite_text(session, incident)

        # Send adventure separator so players can distinguish the new adventure
        title = session.sketch&.dig('title') || 'Adventure'
        separator = {
          content: "━━━ #{title} ━━━",
          html: "<div class='auto-gm-separator'>━━━ #{ERB::Util.html_escape(title)} ━━━</div>",
          type: 'auto_gm_separator'
        }
        BroadcastService.to_room(room_id, separator, type: :auto_gm_separator)

        # Broadcast to the room
        BroadcastService.to_room(
          room_id,
          format_gm_message(message),
          type: :auto_gm_narration,
          sender_instance: nil,
          auto_gm_session_id: session.id
        )

        # Also send individually to participants who might be elsewhere
        session.participant_instances.each do |participant|
          next if participant.current_room_id == room_id

          BroadcastService.to_character(
            participant,
            format_gm_message(message),
            type: :auto_gm_narration
          )
        end
      end

      # NOTE: format_gm_message is inherited from AutoGmFormatHelper

      # Spawn NPCs designated for the initial stage
      # @param session [AutoGmSession] the session
      def spawn_initial_npcs(session)
        npcs_to_spawn = session.sketch['npcs_to_spawn'] || []

        # Spawn NPCs for stage 0 (inciting incident)
        initial_npcs = npcs_to_spawn.select { |n| (n['location_stage'] || 0) == 0 }

        initial_npcs.filter_map do |npc_data|
          spawn_npc(session, npc_data)
        end
      end

      # Spawn a single NPC
      # @param session [AutoGmSession] the session
      # @param npc_data [Hash] NPC configuration
      # @return [CharacterInstance, nil] the spawned NPC
      def spawn_npc(session, npc_data)
        room = session.current_room || session.starting_room
        return nil unless room

        # Try to find matching archetype
        archetype = find_archetype(npc_data['archetype_hint'])

        # Generate new adversary if no archetype found and this is a combat NPC
        if archetype.nil? && npc_data['generate_if_missing'] != false
          archetype = generate_adversary_archetype(session, npc_data)
        end

        if archetype && defined?(NpcSpawnService)
          npc = NpcSpawnService.spawn_from_template(
            archetype,
            room,
            auto_gm_session_id: session.id,
            disposition: npc_data['disposition'] || 'neutral'
          )

          # Track in session world state
          if npc
            update_world_state(session, 'npcs_spawned', {
              id: npc.id,
              name: DisplayHelper.character_display_name(npc),
              role: npc_data['role'],
              archetype: archetype.name
            })

            return {
              instance: npc,
              archetype: archetype,
              disposition: npc_data['disposition'] || 'neutral',
              role: npc_data['role']
            }
          end

          nil
        else
          # Log that we couldn't spawn (no archetype found)
          nil
        end
      rescue StandardError => e
        warn "[AutoGmInciteService] Failed to spawn NPC for session #{session&.id} (hint=#{npc_data['archetype_hint'].inspect}, name=#{npc_data['name'].inspect}): #{e.message}"
        nil
      end

      # NOTE: find_archetype and generate_adversary_archetype are provided
      # by AutoGmArchetypeConcern (extended above)

      # Initialize the session's world state
      # @param session [AutoGmSession] the session
      # @param incident [Hash] the incident data
      def initialize_world_state(session, incident)
        # Must deep-dup to avoid Sequel JSONB dirty-tracking issue
        world_state = JSON.parse((session.world_state || {}).to_json)

        world_state['npcs_spawned'] ||= []
        world_state['items_appeared'] ||= []
        world_state['secrets_revealed'] ||= []
        world_state['disposition_changes'] ||= []
        world_state['incident_type'] = incident['type']
        world_state['incident_npc'] = incident['npc_involved']
        world_state['incited_at'] = Time.now.iso8601

        session.update(world_state: Sequel.pg_jsonb_wrap(world_state))
      end

      # Update world state with new data
      # @param session [AutoGmSession] the session
      # @param key [String] the state key
      # @param value [Object] the value to add
      def update_world_state(session, key, value)
        # Must deep-dup to avoid Sequel JSONB dirty-tracking issue
        state = JSON.parse((session.world_state || {}).to_json)
        state[key] ||= []
        state[key] << value
        session.update(world_state: Sequel.pg_jsonb_wrap(state))
      end

      # Start combat for attack incidents when hostile NPCs are present.
      # Uses FightService.start_fight to leverage normal combat setup.
      def start_incident_combat(session, incident, spawned_npcs)
        return nil unless incident_attack?(incident)
        return nil if spawned_npcs.nil? || spawned_npcs.empty?

        room = session.current_room || session.starting_room
        return nil unless room

        participants = session.participant_instances.select { |ci| ci && ci.current_room_id == room.id }
        return nil if participants.empty?

        hostile_spawns = spawned_npcs.select do |spawn|
          disposition = spawn[:disposition].to_s.strip.downcase
          %w[hostile aggressive].include?(disposition)
        end
        hostile_spawns = spawned_npcs if hostile_spawns.empty?
        return nil if hostile_spawns.empty?

        initiator = participants.first
        target_npc = hostile_spawns.first[:instance]
        return nil unless initiator && target_npc

        fight_service = FightService.start_fight(room: room, initiator: initiator, target: target_npc, mode: 'normal')

        participants[1..]&.each do |ci|
          fight_service.add_participant(ci, target_instance: target_npc)
        end

        hostile_spawns[1..]&.each do |spawn|
          npc_instance = spawn[:instance]
          next unless npc_instance

          fight_service.add_participant(npc_instance, target_instance: initiator)
        end

        apply_balancing_to_auto_gm_fight(fight_service.fight, participants, hostile_spawns, session)
        session.enter_combat!(fight_service.fight)
        fight_service.fight
      rescue StandardError => e
        warn "[AutoGmInciteService] Failed to start attack combat for session #{session&.id}: #{e.message}"
        nil
      end

      def incident_attack?(incident)
        return false unless incident

        incident_type = incident['type'].to_s.strip.downcase
        immediate_threat = incident['immediate_threat'] == true
        incident_type == 'attack' && immediate_threat
      end

      # Apply battle-balancer stat modifiers to NPC participants for Auto-GM fights.
      # Auto-GM fights are created from already-spawned NPC instances, so this
      # pass tunes their combat stats in-place using the selected variant.
      def apply_balancing_to_auto_gm_fight(fight, participants, hostile_spawns, session)
        pc_ids = participants.filter_map { |ci| ci&.character&.id }.uniq
        archetype_ids = hostile_spawns.filter_map { |spawn| spawn[:archetype]&.id }.uniq
        return if pc_ids.empty? || archetype_ids.empty?

        balancer = BattleBalancingService.new(
          pc_ids: pc_ids,
          mandatory_archetype_ids: archetype_ids,
          optional_archetype_ids: []
        )
        result = balancer.balance!

        variant_key = map_auto_gm_difficulty_to_variant(session.sketch&.dig('difficulty'))
        variants = result[:difficulty_variants] || {}
        selected_variant = variants[variant_key] || variants['normal'] || {}
        modifiers = selected_variant[:stat_modifiers] || selected_variant['stat_modifiers'] || result[:stat_modifiers] || {}

        apply_stat_modifiers_to_fight_npcs(fight, modifiers)
      rescue StandardError => e
        warn "[AutoGmInciteService] Failed to apply balance to fight #{fight&.id} for session #{session&.id}: #{e.message}"
      end

      def map_auto_gm_difficulty_to_variant(difficulty)
        case difficulty.to_s.strip.downcase
        when 'easy'
          'easy'
        when 'hard'
          'hard'
        when 'deadly'
          'nightmare'
        else
          'normal'
        end
      end

      def apply_stat_modifiers_to_fight_npcs(fight, modifiers)
        participants = fight.fight_participants_dataset.eager(character_instance: :character).all
        participants.each do |participant|
          ci = participant.character_instance
          archetype = ci&.character&.npc_archetype
          next unless archetype

          modifier = modifiers[archetype.id] || modifiers[archetype.id.to_s] || 0.0
          next if modifier.to_f.zero?

          stats = PowerCalculatorService.apply_difficulty_modifier(archetype, modifier.to_f)
          adjusted_max_hp = stats[:max_hp] || participant.max_hp
          participant.update(
            max_hp: adjusted_max_hp,
            current_hp: adjusted_max_hp,
            npc_damage_bonus: stats[:damage_bonus] || participant.npc_damage_bonus,
            npc_defense_bonus: stats[:defense_bonus] || participant.npc_defense_bonus,
            npc_speed_modifier: stats[:speed_modifier] || participant.npc_speed_modifier,
            npc_damage_dice_count: stats[:damage_dice_count] || participant.npc_damage_dice_count,
            npc_damage_dice_sides: stats[:damage_dice_sides] || participant.npc_damage_dice_sides
          )
        end
      end

      # Build prompt for generating inciting narrative
      # @param session [AutoGmSession] the session
      # @param incident [Hash] incident data
      # @param context [Hash] context data
      # @return [String] the prompt
      def build_narrative_prompt(session, incident, context)
        sketch = session.sketch

        GamePrompts.get(
          'auto_gm_incite.narrative',
          title: sketch['title'],
          setting: sketch.dig('setting', 'flavor'),
          mood: sketch.dig('setting', 'mood'),
          incident_type: incident['type'],
          incident_description: incident['description'],
          npc_involved: incident['npc_involved'] || 'none',
          immediate_threat: incident['immediate_threat'],
          location: context.dig(:room_context, :name),
          characters: context[:participant_context]&.map { |p| p[:name] }&.join(', ')
        )
      end
    end
  end
end
