# frozen_string_literal: true

module AutoGm
  # AutoGmResolutionService handles ending Auto-GM sessions.
  #
  # When a session ends (success, failure, or abandonment):
  # - Creates a WorldMemory record for the session
  # - Links participating characters and locations
  # - Applies any rewards or consequences
  # - Updates NPC dispositions based on events
  # - Cleans up spawned NPCs if appropriate
  # - Broadcasts resolution message
  #
  class AutoGmResolutionService
    class << self
      # Resolve a session
      # @param session [AutoGmSession] the session
      # @param resolution_type [Symbol] :success, :failure, or :abandoned
      # @return [Hash] { success:, memory:, error: }
      def resolve(session, resolution_type:)
        return { success: false, error: 'Session already resolved' } if session.resolved?

        # Update session status
        session.resolve!(resolution_type)

        # Create world memory from session
        memory = create_session_memory(session, resolution_type)

        # Narrative extraction for Auto-GM outcomes
        enqueue_narrative_extraction(memory)

        # Apply rewards or consequences
        if resolution_type == :success
          apply_rewards(session)
        elsif resolution_type == :failure
          apply_consequences(session)
        end

        # Update NPC dispositions
        update_dispositions(session)

        # Cleanup spawned NPCs
        cleanup_session_npcs(session)

        # Broadcast resolution
        broadcast_resolution(session, resolution_type)

        { success: true, memory: memory }
      rescue StandardError => e
        { success: false, error: "Resolution error: #{e.message}" }
      end

      # Abandon a session (timeout or manual abort)
      # @param session [AutoGmSession] the session
      # @param reason [String] reason for abandonment
      # @return [Hash] result
      def abandon(session, reason: 'Abandoned')
        session.update(
          status: 'abandoned',
          resolved_at: Time.now,
          resolution_type: 'abandoned'
        )

        # Create a minimal world memory
        memory = create_session_memory(session, :abandoned)

        # Cleanup
        cleanup_session_npcs(session)

        # Broadcast
        room_id = session.current_room_id || session.starting_room_id
        abandon_text = "The adventure fades away... (#{reason})"
        BroadcastService.to_room(
          room_id,
          {
            content: abandon_text,
            html: "<div class='auto-gm-abandoned'><em>The adventure fades away... (#{reason})</em></div>",
            type: 'auto_gm_abandoned'
          },
          type: :auto_gm_abandoned
        )

        # Log Auto-GM abandonment to character stories
        IcActivityService.record(
          room_id: room_id, content: abandon_text,
          sender: nil, type: :auto_gm
        )

        { success: true, memory: memory }
      end

      # Generate a final session summary
      # @param session [AutoGmSession] the session
      # @return [String]
      def generate_session_summary(session)
        sketch = session.sketch

        # Get the best available summary
        best_summary = AutoGmSummary.best_for_context(session)
        return best_summary.content if best_summary

        # Generate fresh if no summaries
        actions = session.auto_gm_actions_dataset
          .where(action_type: 'emit')
          .exclude(emit_text: nil)
          .order(:created_at)
          .limit(20)
          .all

        world_state = session.world_state || {}

        # Build NPC context
        npcs_spawned = world_state['npcs_spawned'] || []
        npcs_involved = if npcs_spawned.any?
          npcs_spawned.map { |n| "#{n['name']} (#{n['role']}, #{n['disposition']})" }.join(', ')
        else
          'None'
        end

        # Build twist/secrets context
        secrets = sketch.dig('secrets_twists', 'secrets') || []
        revealed = world_state['secrets_revealed'] || []
        twist_triggered = world_state['twist_triggered']

        twist_info = if twist_triggered
          "#{sketch.dig('secrets_twists', 'twist_type')}: #{sketch.dig('secrets_twists', 'twist_description')}"
        else
          'Not triggered'
        end

        # Build consequences context
        consequences = if world_state['rewards_granted']
          "Rewards: #{(world_state['rewards_granted'] || []).join(', ')}"
        elsif world_state['consequences_applied']
          "Consequences: #{(world_state['consequences_applied'] || []).join(', ')}"
        else
          'None'
        end

        # Locations
        locations_used = (session.location_ids_used || []).map do |lid|
          Location[lid]&.name
        end.compact

        prompt = GamePrompts.get(
          'auto_gm.resolution_summary',
          title: sketch['title'],
          mission_objective: sketch.dig('mission', 'objective'),
          resolution_type: session.resolution_type,
          npcs_involved: npcs_involved,
          twist_info: twist_info,
          secrets_revealed: revealed.any? ? revealed.join(', ') : 'None',
          locations_visited: locations_used.any? ? locations_used.join(', ') : 'Starting area only',
          key_events: actions.map(&:emit_text).compact.last(10).join("\n- "),
          consequences: consequences
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: 'anthropic',
          model: 'claude-sonnet-4-6',
          options: {
            temperature: 0.6,
            timeout: 30
          }
        )

        result[:success] ? result[:text].strip : "Adventure '#{sketch['title']}' concluded."
      end

      private

      # Create a WorldMemory record for the session
      # @param session [AutoGmSession] the session
      # @param resolution_type [Symbol] how it resolved
      # @return [WorldMemory, nil]
      def enqueue_narrative_extraction(memory)
        return unless memory
        return unless defined?(NarrativeExtractionService)
        return unless defined?(WorldMemory) && WorldMemory.respond_to?(:[])

        memory_id = memory.id
        return unless memory_id

        worker = Thread.new(memory_id) do |id|
          begin
            extraction_memory = WorldMemory[id]
            next unless extraction_memory

            NarrativeExtractionService.extract_comprehensive(extraction_memory)
          rescue StandardError => e
            warn "[AutoGmResolution] Narrative extraction failed for memory #{id}: #{e.message}"
          end
        end
        worker.report_on_exception = false if worker.respond_to?(:report_on_exception=)
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to enqueue narrative extraction: #{e.message}"
      end

      def create_session_memory(session, resolution_type)
        return nil unless defined?(WorldMemory)

        summary = generate_session_summary(session)
        raw_log = compile_session_log(session)

        # Calculate importance based on resolution
        importance = case resolution_type
        when :success then 7
        when :failure then 5
        when :abandoned then 3
        else 5
        end

        # Create the memory
        memory = WorldMemory.create(
          summary: summary,
          raw_log: raw_log,
          importance: importance,
          publicity_level: 'semi_public',
          source_type: 'activity',
          started_at: session.started_at || session.created_at,
          ended_at: session.resolved_at || Time.now,
          memory_at: Time.now
        )

        # Link characters
        session.participant_instances.each do |p|
          memory.add_character!(p.character, role: 'participant')
        end

        # Link NPCs that played significant roles
        npcs_spawned = (session.world_state || {})['npcs_spawned'] || []
        npcs_spawned.each do |npc_data|
          npc_id = npc_data['id'] || npc_data[:id]
          next unless npc_id

          instance = CharacterInstance[npc_id]
          next unless instance&.character

          role = npc_data['role'] || npc_data[:role] || 'mentioned'
          # Map adventure roles to memory roles
          memory_role = %w[antagonist ally guide].include?(role) ? 'participant' : 'mentioned'
          memory.add_character!(instance.character, role: memory_role)
        end

        # Link locations
        location_ids = session.location_ids_used || []
        location_ids << session.starting_room&.location_id
        location_ids.compact.uniq.each do |loc_id|
          location = Location[loc_id]
          next unless location

          # Add primary room for this location
          primary_room = location.rooms.first
          memory.add_location!(primary_room, is_primary: loc_id == session.starting_room&.location_id) if primary_room
        end

        # Generate embedding for semantic search
        if defined?(EmbeddingService)
          EmbeddingService.create_for(memory, summary)
        end

        memory
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to create session memory for session #{session&.id} (resolution=#{resolution_type}): #{e.message}"
        nil
      end

      # Compile session log from actions
      # @param session [AutoGmSession] the session
      # @return [String]
      def compile_session_log(session)
        actions = session.auto_gm_actions_dataset.order(:sequence_number).all

        log_parts = [
          "=== Auto-GM Session: #{session.sketch['title']} ===",
          "Started: #{session.started_at || session.created_at}",
          "Resolved: #{session.resolved_at}",
          "Resolution: #{session.resolution_type}",
          "Participants: #{session.participant_instances.map { |p| DisplayHelper.character_display_name(p) }.join(', ')}",
          "",
          "=== Actions ==="
        ]

        actions.each do |action|
          log_parts << "[#{action.action_type}] #{action.emit_text}" if action.emit_text
        end

        log_parts.join("\n")
      end

      # Apply rewards for successful completion
      # @param session [AutoGmSession] the session
      def apply_rewards(session)
        rewards = session.sketch.dig('rewards_perils', 'rewards') || []
        return if rewards.empty?

        # Parse total currency value from rewards
        total_value = parse_currency_from_rewards(rewards)
        total_value = GameConfig::AutoGm::LOOT[:default_reward_value] if total_value.zero?

        # Distribute to each participant
        distributed = {}
        session.participant_instances.each do |participant|
          character = participant.character
          next unless character

          # Check hourly cap
          allowance = LootTracker.remaining_allowance(character)
          capped_amount = [total_value, allowance].min

          next if capped_amount <= 0

          # Give money to wallet
          success = give_money_to_character(participant, capped_amount)

          if success
            LootTracker.record_loot(character, capped_amount)
            distributed[character.id] = capped_amount

            # Notify character
            broadcast_loot_message(participant, capped_amount, total_value)
          end
        end

        # Log rewards given (deep-dup to avoid Sequel JSONB dirty-tracking issue)
        state = JSON.parse((session.world_state || {}).to_json)
        state['rewards_granted'] = rewards
        state['loot_distributed'] = distributed
        session.update(world_state: Sequel.pg_jsonb_wrap(state))
      end

      # Parse currency amounts from reward descriptions
      # @param rewards [Array<String>]
      # @return [Integer] total currency value
      def parse_currency_from_rewards(rewards)
        patterns = GameConfig::AutoGm::LOOT[:currency_patterns]
        total = 0

        rewards.each do |reward|
          patterns.each do |pattern|
            if (match = reward.match(pattern))
              total += match[1].to_i
              break # Only match first pattern per reward
            end
          end
        end

        total
      end

      # Give money directly to a character's wallet
      # @param participant [CharacterInstance]
      # @param amount [Integer]
      # @return [Boolean] success
      def give_money_to_character(participant, amount)
        # Get default currency for this universe
        universe = participant.current_room&.location&.zone&.world&.universe
        return false unless universe

        currency = Currency.where(universe_id: universe.id, is_primary: true).first
        currency ||= Currency.where(universe_id: universe.id).first
        return false unless currency

        # Find or create wallet
        wallet = participant.wallets_dataset.first(currency_id: currency.id)
        wallet ||= Wallet.create(
          character_instance: participant,
          currency: currency,
          balance: 0
        )

        wallet.add(amount)
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to give money: #{e.message}"
        false
      end

      # Broadcast loot message to participant
      # @param participant [CharacterInstance]
      # @param amount [Integer] actual amount given
      # @param requested [Integer] original amount before cap
      def broadcast_loot_message(participant, amount, requested)
        message = if amount < requested
          "You find valuables worth $#{amount}! (Capped from $#{requested} due to hourly limit)"
        else
          "You find valuables worth $#{amount}!"
        end

        BroadcastService.to_character(
          participant,
          { content: message, type: 'loot_reward' },
          type: :loot_reward
        )
      end

      # Apply consequences for failure
      # @param session [AutoGmSession] the session
      def apply_consequences(session)
        perils = session.sketch.dig('rewards_perils', 'perils') || []
        return if perils.empty?

        applied_details = {}
        current_room = session.current_room || session.starting_room

        session.participant_instances.each do |participant|
          character = participant.character
          next unless character

          consequences = []

          perils.each do |peril|
            case peril.to_s
            when /money_loss[:\s]*(\d+)/i
              amount = Regexp.last_match(1).to_i
              if apply_money_loss(participant, amount)
                consequences << "Lost #{amount} coins"
              end
            when /injury[:\s]*(\d+)/i
              amount = [Regexp.last_match(1).to_i, 3].min # Cap at 3 HP
              amount = [amount, 1].max # Minimum 1 HP
              if apply_injury(participant, amount)
                severity = case amount
                when 1 then 'minor'
                when 2 then 'moderate'
                else 'serious'
                end
                consequences << "Suffered #{severity} injuries (-#{amount} HP)"
              end
            when /item_damage/i
              if (item = damage_random_item(participant))
                consequences << "#{item.name} was damaged"
              end
            when /item_lost/i
              if (item = lose_random_item(participant, current_room))
                consequences << "Lost #{item.name}"
              end
            end
          end

          if consequences.any?
            applied_details[character.id] = consequences
            broadcast_consequence_message(participant, consequences)
          end
        end

        # Log what was applied (deep-dup to avoid Sequel JSONB dirty-tracking issue)
        state = JSON.parse((session.world_state || {}).to_json)
        state['consequences_applied'] = perils
        state['consequences_details'] = applied_details
        session.update(world_state: Sequel.pg_jsonb_wrap(state))
      end

      # Apply money loss consequence
      # @param participant [CharacterInstance]
      # @param amount [Integer]
      # @return [Boolean] success
      def apply_money_loss(participant, amount)
        universe = participant.current_room&.location&.zone&.world&.universe
        return false unless universe

        currency = Currency.where(universe_id: universe.id, is_primary: true).first
        currency ||= Currency.where(universe_id: universe.id).first
        return false unless currency

        wallet = participant.wallets_dataset.first(currency_id: currency.id)
        return false unless wallet

        # Remove up to what they have
        actual_loss = [amount, wallet.balance].min
        return false if actual_loss <= 0

        wallet.remove(actual_loss)
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to apply money loss: #{e.message}"
        false
      end

      # Apply injury (HP damage) consequence
      # @param participant [CharacterInstance]
      # @param amount [Integer]
      # @return [Boolean] success
      def apply_injury(participant, amount)
        return false unless participant.respond_to?(:health) && participant.health

        # Don't kill the character - leave at least 1 HP
        new_health = [participant.health - amount, 1].max
        return false if new_health >= participant.health

        participant.update(health: new_health)
        true
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to apply injury: #{e.message}"
        false
      end

      # Damage a random item the character is carrying
      # @param participant [CharacterInstance]
      # @return [Item, nil] the damaged item
      def damage_random_item(participant)
        # Get non-quest, non-container items
        items = participant.objects_dataset
          .exclude(item_type: %w[container key quest_item])
          .all
        return nil if items.empty?

        item = items.sample

        # Mark as damaged if the item has a condition field
        if item.respond_to?(:condition=)
          current = item.condition || 'good'
          new_condition = case current
          when 'pristine', 'excellent' then 'good'
          when 'good' then 'worn'
          when 'worn' then 'damaged'
          when 'damaged' then 'broken'
          else 'damaged'
          end
          item.update(condition: new_condition)
        end

        item
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to damage item: #{e.message}"
        nil
      end

      # Lose a random non-essential item (drop it in the room)
      # @param participant [CharacterInstance]
      # @param room [Room]
      # @return [Item, nil] the lost item
      def lose_random_item(participant, room)
        # Get non-equipped, non-essential items
        items = participant.objects_dataset
          .exclude(equipped: true)
          .exclude(item_type: %w[container key quest_item])
          .all
        return nil if items.empty?

        item = items.sample

        if room
          item.move_to_room(room)
        else
          # If no room, just detach from character
          item.update(character_instance_id: nil)
        end

        item
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to lose item: #{e.message}"
        nil
      end

      # Broadcast consequence message to participant
      # @param participant [CharacterInstance]
      # @param consequences [Array<String>]
      def broadcast_consequence_message(participant, consequences)
        message = "The failed adventure has consequences: #{consequences.join(', ')}"

        BroadcastService.to_character(
          participant,
          { content: message, type: 'consequence' },
          type: :consequence
        )
      end

      # Update NPC dispositions based on session events
      # @param session [AutoGmSession] the session
      def update_dispositions(session)
        state = JSON.parse((session.world_state || {}).to_json)
        disposition_changes = state['disposition_changes'] || []
        return if disposition_changes.empty?

        spawned_npcs = state['npcs_spawned'] || []
        participant_characters = resolve_participant_characters(session)
        state_changed = false

        disposition_changes.each do |raw_change|
          change = normalize_disposition_change(raw_change)
          next unless change

          to_disposition = parse_to_disposition(change)
          next unless to_disposition

          if apply_disposition_to_spawned_npcs!(spawned_npcs, change, to_disposition)
            state_changed = true
          end

          npc_character = find_npc_character_for_disposition_change(spawned_npcs, change)
          next unless npc_character && defined?(NpcRelationship)

          participant_characters.each do |pc_character|
            next unless pc_character

            apply_disposition_to_relationship(npc_character, pc_character, to_disposition, change)
          end
        end

        session.update(world_state: Sequel.pg_jsonb_wrap(state)) if state_changed
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to update dispositions: #{e.message}"
      end

      def resolve_participant_characters(session)
        if session.respond_to?(:participant_characters)
          Array(session.participant_characters).compact
        else
          Array(session.participant_instances).map(&:character).compact
        end
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to resolve participant characters: #{e.message}"
        []
      end

      def normalize_disposition_change(change)
        return nil unless change.is_a?(Hash)

        {
          npc: fetch_change_value(change, 'npc', 'npc_name', 'name'),
          npc_id: fetch_change_value(change, 'npc_id', 'id'),
          change: fetch_change_value(change, 'change', 'disposition_change'),
          from: fetch_change_value(change, 'from', 'old_disposition'),
          to: fetch_change_value(change, 'to', 'new_disposition')
        }
      end

      def fetch_change_value(hash, *keys)
        keys.each do |key|
          return hash[key] if hash.key?(key)

          sym = key.to_sym
          return hash[sym] if hash.key?(sym)
        end

        nil
      end

      def parse_to_disposition(change)
        to = normalize_disposition(change[:to])
        return to if to

        change_text = change[:change].to_s.strip
        if change_text.include?('->')
          _, rhs = change_text.split('->', 2)
          to = normalize_disposition(rhs)
          return to if to
        end

        normalize_disposition(change_text)
      end

      def normalize_disposition(value)
        raw = value.to_s.strip.downcase
        return nil if raw.empty?

        aliases = {
          'friend' => 'friendly',
          'helpful' => 'friendly',
          'allied' => 'ally',
          'enemy' => 'hostile',
          'aggressive' => 'hostile',
          'suspicious' => 'wary',
          'afraid' => 'fearful'
        }

        aliases[raw] || raw
      end

      def apply_disposition_to_spawned_npcs!(spawned_npcs, change, disposition)
        return false unless spawned_npcs.is_a?(Array)

        target_id = change[:npc_id]&.to_i
        target_name = change[:npc].to_s.strip.downcase
        changed = false

        spawned_npcs.each do |npc|
          next unless npc.is_a?(Hash)

          npc_id = fetch_change_value(npc, 'id')&.to_i
          npc_name = fetch_change_value(npc, 'name').to_s.strip.downcase

          matches = if target_id && target_id.positive?
            npc_id == target_id
          else
            !target_name.empty? && npc_name == target_name
          end
          next unless matches

          current = normalize_disposition(fetch_change_value(npc, 'disposition'))
          next if current == disposition

          npc['disposition'] = disposition
          npc[:disposition] = disposition if npc.key?(:disposition)
          changed = true
        end

        changed
      end

      def find_npc_character_for_disposition_change(spawned_npcs, change)
        instance_id = change[:npc_id]&.to_i

        unless instance_id && instance_id.positive?
          target_name = change[:npc].to_s.strip.downcase

          if !target_name.empty? && spawned_npcs.is_a?(Array)
            match = spawned_npcs.find do |npc|
              next false unless npc.is_a?(Hash)

              npc_name = fetch_change_value(npc, 'name').to_s.strip.downcase
              npc_name == target_name && fetch_change_value(npc, 'id')
            end
            instance_id = fetch_change_value(match, 'id')&.to_i if match
          end
        end

        return nil unless instance_id && instance_id.positive?

        instance = CharacterInstance[instance_id]
        instance&.character
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to resolve NPC for disposition change: #{e.message}"
        nil
      end

      def apply_disposition_to_relationship(npc_character, pc_character, disposition, change)
        relationship = NpcRelationship.find_or_create_for(npc: npc_character, pc: pc_character)
        targets = disposition_targets(disposition)
        return unless targets

        current_sentiment = relationship.sentiment || 0.0
        current_trust = relationship.trust || 0.5
        target_sentiment = ((current_sentiment + targets[:sentiment]) / 2.0).round(3)
        target_trust = ((current_trust + targets[:trust]) / 2.0).round(3)

        event_text = build_disposition_event_text(change, disposition, npc_character)
        relationship.record_interaction(
          sentiment_delta: target_sentiment - current_sentiment,
          trust_delta: target_trust - current_trust,
          notable_event: event_text
        )
      rescue StandardError => e
        warn "[AutoGmResolution] Failed to apply relationship disposition update: #{e.message}"
      end

      def disposition_targets(disposition)
        case disposition
        when 'ally'
          { sentiment: 0.85, trust: 0.90 }
        when 'friendly'
          { sentiment: 0.55, trust: 0.70 }
        when 'neutral'
          { sentiment: 0.00, trust: 0.50 }
        when 'wary'
          { sentiment: -0.35, trust: 0.35 }
        when 'fearful'
          { sentiment: -0.20, trust: 0.25 }
        when 'hostile'
          { sentiment: -0.80, trust: 0.15 }
        else
          nil
        end
      end

      def build_disposition_event_text(change, disposition, npc_character)
        npc_name = change[:npc].to_s.strip
        npc_name = npc_character.forename if npc_name.empty? && npc_character.respond_to?(:forename)
        npc_name = "NPC##{npc_character.id}" if npc_name.empty?

        change_text = change[:change].to_s.strip
        if change_text.empty?
          "Auto-GM disposition set for #{npc_name}: #{disposition}"
        else
          "Auto-GM disposition shift for #{npc_name}: #{change_text}"
        end
      end

      # Cleanup NPCs spawned for this session
      # @param session [AutoGmSession] the session
      def cleanup_session_npcs(session)
        npcs_spawned = session.world_state&.dig('npcs_spawned') || []

        npcs_spawned.each do |npc_data|
          npc_id = npc_data['id'] || npc_data[:id]
          next unless npc_id

          # Remove temporary NPCs if they have the auto_gm_session_id marker
          instance = CharacterInstance[npc_id]
          next unless instance

          # Only despawn if NPC was created for this session
          # Check if NPC should persist based on role
          role = npc_data['role'] || npc_data[:role]
          persist_roles = %w[ally guide]

          if persist_roles.include?(role)
            # Keep ally/guide NPCs but mark session as ended
          else
            # Despawn temporary NPCs
            spawn_inst = defined?(NpcSpawnInstance) &&
              NpcSpawnInstance.first(character_instance_id: instance.id, active: true)
            if spawn_inst && defined?(NpcSpawnService)
              NpcSpawnService.despawn_npc(spawn_inst)
            else
              instance.update(online: false)
            end
          end
        end
      end

      # Broadcast the resolution to participants
      # @param session [AutoGmSession] the session
      # @param resolution_type [Symbol] how it resolved
      def broadcast_resolution(session, resolution_type)
        sketch = session.sketch
        title = sketch['title'] || 'The Adventure'

        message = case resolution_type
                  when :success
                    "Adventure Complete! #{title} - Victory! The mission was a success."
                  when :failure
                    "Adventure Failed! #{title} - The mission was not completed. Perhaps next time..."
                  when :abandoned
                    "Adventure Abandoned. #{title} - The adventure fades into memory."
                  else
                    "Adventure Concluded. #{title}"
                  end

        room_id = session.current_room_id || session.starting_room_id

        BroadcastService.to_room(
          room_id,
          {
            content: message,
            html: "<div class='auto-gm-resolution auto-gm-#{resolution_type}'><strong>#{ERB::Util.html_escape(message)}</strong></div>",
            type: 'auto_gm_resolution'
          },
          type: :auto_gm_resolution,
          auto_gm_session_id: session.id,
          resolution_type: resolution_type.to_s
        )

        # Log Auto-GM resolution to character stories
        IcActivityService.record(
          room_id: room_id, content: message,
          sender: nil, type: :auto_gm
        )

        # Also notify participants directly
        session.participant_instances.each do |participant|
          next if participant.current_room_id == room_id

          BroadcastService.to_character(
            participant,
            { content: message, type: 'auto_gm_resolution' },
            type: :auto_gm_resolution
          )

          # Log for remote participants too
          IcActivityService.record_for(
            recipients: [participant], content: message,
            sender: nil, type: :auto_gm
          )
        end
      end
    end
  end
end
