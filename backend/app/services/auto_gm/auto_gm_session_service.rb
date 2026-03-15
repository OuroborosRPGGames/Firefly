# frozen_string_literal: true

module AutoGm
  # AutoGmSessionService is the main orchestrator for Auto-GM adventures.
  #
  # This service manages the full lifecycle of an Auto-GM session:
  # 1. Context Gathering - gather world memories, nearby locations
  # 2. Brainstorming - parallel Kimi-k2 + GPT-5.4 ideation
  # 3. Synthesis - Opus 4.5 combines into adventure sketch
  # 4. Inciting - deploy the inciting incident
  # 5. GM Loop - Sonnet 4.6 makes decisions, executes actions
  # 6. Resolution - end session, create world memory
  #
  # Sessions auto-abandon after 2 hours of inactivity.
  #
  class AutoGmSessionService
    # Maximum session duration before auto-abandonment
    SESSION_TIMEOUT_SECONDS = 2 * 60 * 60  # 2 hours

    # Poll interval for GM loop
    GM_LOOP_POLL_INTERVAL = 2  # seconds

    # Minimum time between GM actions
    GM_ACTION_COOLDOWN = 30  # seconds

    # Heartbeat staleness threshold — if no heartbeat for this long, loop is assumed dead.
    # Must be larger than a normal decision cycle (decision timeout + action/compression overhead)
    # to avoid watchdog false-positives while a healthy loop is inside a long LLM call.
    HEARTBEAT_STALE_SECONDS = [GameConfig::AutoGm::TIMEOUTS[:decision].to_i + 45, 120].max

    class << self
      extend StringHelper

      # Start a new Auto-GM session
      # @param room [Room] starting location
      # @param participants [Array<CharacterInstance>] characters to include
      # @param trigger_context [Hash] how session was triggered
      # @param options [Hash] duration_hint, etc.
      # @return [AutoGmSession]
      def start_session(room:, participants:, trigger_context: {}, options: {})
        # Validate inputs
        raise ArgumentError, 'Room is required' unless room
        raise ArgumentError, 'At least one participant is required' if participants.nil? || participants.empty?
        raise ArgumentError, 'Auto-GM is currently disabled.' unless auto_gm_enabled?

        # Resolve universe and stat block from the room
        universe = room.respond_to?(:universe) ? room.universe : nil
        stat_block = universe&.default_stat_block

        session = AutoGmSession.create(
          status: 'gathering',
          starting_room_id: room.id,
          current_room_id: room.id,
          participant_ids: Sequel.pg_array(participants.map(&:id)),
          chaos_level: 5,
          created_by_id: trigger_context[:initiator_id],
          universe_id: universe&.id,
          stat_block_id: stat_block&.id
        )

        # Execute pipeline in background thread
        Thread.new do
          execute_pipeline(session, options)
        rescue StandardError => e
          warn "[AutoGmPipeline] THREAD CRASH session #{session.id}: #{e.class}: #{e.message}"
          warn e.backtrace.first(10).join("\n")
          fail_session(session, "Thread crash: #{e.class}: #{e.message}") rescue nil
        end

        session
      end

      # Execute the full Auto-GM pipeline
      # @param session [AutoGmSession] the session
      # @param options [Hash] pipeline options
      def execute_pipeline(session, options = {})
        begin
          # Phase 1: Context gathering
          warn "[AutoGmPipeline] Session #{session.id}: gathering context..."
          session.update(status: 'gathering')
          context = AutoGmContextService.gather(session)
          session.update(memory_context: context)
          warn "[AutoGmPipeline] Session #{session.id}: context gathered (#{context.keys.join(', ')})"

          # Phase 2: Brainstorming (parallel)
          warn "[AutoGmPipeline] Session #{session.id}: brainstorming..."
          session.update(status: 'sketching')
          brainstorm_result = AutoGmBrainstormService.brainstorm(
            session: session,
            context: context,
            options: options
          )

          unless brainstorm_result[:success]
            return fail_session(session, brainstorm_result[:errors]&.join(', ') || 'Brainstorming failed')
          end

          session.update(brainstorm_outputs: brainstorm_result[:outputs])

          # Phase 3: Synthesis (Opus)
          warn "[AutoGmPipeline] Session #{session.id}: synthesizing..."
          synthesis_result = AutoGmSynthesisService.synthesize(
            brainstorm_outputs: brainstorm_result[:outputs],
            context: context,
            options: options
          )

          unless synthesis_result[:success]
            return fail_session(session, synthesis_result[:error] || 'Synthesis failed')
          end

          locations = synthesis_result[:locations_used] || []
          session.update(
            sketch: synthesis_result[:sketch],
            synthesis_output: synthesis_result,
            location_ids_used: Sequel.pg_array(locations.map(&:to_i), :integer)
          )
          warn "[AutoGmPipeline] Session #{session.id}: synthesis complete - '#{synthesis_result[:sketch]&.dig('title')}'"

          # Phase 4: Inciting incident
          warn "[AutoGmPipeline] Session #{session.id}: deploying inciting incident..."
          session.update(status: 'inciting')
          incite_result = AutoGmInciteService.deploy(session)

          unless incite_result[:success]
            return fail_session(session, incite_result[:error] || 'Inciting incident failed')
          end

          # Phase 5: Enter GM loop
          warn "[AutoGmPipeline] Session #{session.id}: entering GM loop"
          session.update(status: 'running', started_at: Time.now)
          run_gm_loop(session)

        rescue StandardError => e
          warn "[AutoGmPipeline] Pipeline error session #{session.id}: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          fail_session(session, "Pipeline error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        end
      end

      # Run the main GM loop
      # @param session [AutoGmSession] the session
      # @param recovered [Boolean] true if restarted by the watchdog
      def run_gm_loop(session, recovered: false)
        loop_owner = "#{Process.pid}:#{Thread.current.object_id}"
        warn "[AutoGmLoop] Session #{session.id}: loop started (owner=#{loop_owner}#{recovered ? ', recovered' : ''})"

        # Claim ownership and write initial heartbeat
        session.update(loop_owner: loop_owner, loop_heartbeat_at: Time.now)

        loop do
          session.reload

          # Check if another process took over (our owner was overwritten)
          if session.loop_owner != loop_owner
            warn "[AutoGmLoop] Session #{session.id}: ownership lost to #{session.loop_owner}, exiting"
            break
          end

          # Check if session should continue
          break unless should_continue_loop?(session)

          # Update heartbeat
          heartbeat!(session, loop_owner)

          # Check for timeout
          if session_timed_out?(session)
            AutoGmResolutionService.abandon(session, reason: 'Session timed out (2 hours)')
            break
          end

          # Skip if GM shouldn't act yet
          unless should_gm_act?(session)
            sleep GM_LOOP_POLL_INTERVAL
            next
          end

          # Get GM decision
          heartbeat!(session, loop_owner)
          decision = AutoGmDecisionService.decide(session)
          heartbeat!(session, loop_owner)

          # Execute action
          AutoGmActionExecutor.execute(session, decision)
          heartbeat!(session, loop_owner)

          # Update compression if needed
          AutoGmCompressionService.update(session)
          heartbeat!(session, loop_owner)

          # Check for random events
          AutoGmEventService.check_random_event(session)
          heartbeat!(session, loop_owner)

          # Short pause between iterations
          sleep GM_LOOP_POLL_INTERVAL
        end
      ensure
        # Clear ownership on exit only if we still own it.
        # Prevents an old loop from erasing ownership claimed by a recovered loop.
        release_loop_ownership(session, loop_owner)
        warn "[AutoGmLoop] Session #{session.id}: loop exited (owner=#{loop_owner})"
      end

      # Get the status of a session
      # @param session [AutoGmSession] the session
      # @return [Hash] status information
      def status(session)
        session.reload
        now = Time.now
        last_activity = session.last_action_at || session.started_at || session.created_at
        inactivity_seconds = last_activity ? [0, (now - last_activity).to_i].max : nil
        timeout_remaining = inactivity_seconds ? [0, SESSION_TIMEOUT_SECONDS - inactivity_seconds].max : nil

        {
          id: session.id,
          status: session.status,
          title: session.sketch&.dig('title'),
          current_stage: session.current_stage,
          total_stages: session.sketch&.dig('structure', 'stages')&.length || 0,
          chaos_level: session.chaos_level,
          countdown: session.countdown,
          participant_count: session.participant_ids.length,
          action_count: session.auto_gm_actions_dataset.count,
          started_at: session.started_at,
          elapsed_seconds: session.started_at ? (now - session.started_at).to_i : nil,
          timeout_in_seconds: timeout_remaining,
          in_combat: session.in_combat?,
          resolved: session.resolved?,
          resolution_type: session.resolution_type
        }
      end

      # End a session manually
      # @param session [AutoGmSession] the session
      # @param resolution_type [Symbol] :success, :failure, or :abandoned
      # @param reason [String] reason for ending
      # @return [Hash] result
      def end_session(session, resolution_type: :abandoned, reason: 'Manually ended')
        case resolution_type
        when :success, :failure
          AutoGmResolutionService.resolve(session, resolution_type: resolution_type)
        else
          AutoGmResolutionService.abandon(session, reason: reason)
        end
      end

      # Remove a participant from a running session without ending it for everyone.
      # If this removes the final participant, the session is abandoned.
      # @param session [AutoGmSession]
      # @param character_instance [CharacterInstance]
      # @return [Hash] { success:, ended:, error: }
      def leave_session(session, character_instance)
        participant_ids = (session.participant_ids || []).to_a
        return { success: false, error: 'You are not in this adventure.' } unless participant_ids.include?(character_instance.id)

        session.remove_participant!(character_instance)
        remaining = (session.participant_ids || []).to_a

        if remaining.empty?
          AutoGmResolutionService.abandon(session, reason: 'All participants left the adventure')
          { success: true, ended: true }
        else
          { success: true, ended: false }
        end
      rescue StandardError => e
        warn "[AutoGmSession] Failed to leave session #{session&.id}: #{e.message}"
        { success: false, error: e.message }
      end

      # Recover orphaned sessions whose GM loop threads have died.
      # Called by the scheduler watchdog. Uses FOR UPDATE SKIP LOCKED
      # to prevent multiple workers from claiming the same session.
      # @return [Integer] number of sessions recovered
      def recover_orphaned_loops
        cutoff = Time.now - HEARTBEAT_STALE_SECONDS

        # Find sessions that should have a loop but don't
        orphans = AutoGmSession
          .where(status: %w[running climax])
          .where {
            (loop_heartbeat_at < cutoff) | Sequel.expr(loop_heartbeat_at: nil)
          }
          .all

        recovered = 0
        orphans.each do |session|
          # Try to claim with row lock — skip if another worker got it first
          claimed = DB.transaction do
            locked = AutoGmSession
              .where(id: session.id, status: %w[running climax])
              .where {
                (loop_heartbeat_at < cutoff) | Sequel.expr(loop_heartbeat_at: nil)
              }
              .for_update
              .skip_locked
              .first

            next false unless locked

            # Claim it by writing a fresh heartbeat
            locked.update(loop_heartbeat_at: Time.now, loop_owner: "#{Process.pid}:claiming")
            locked
          end

          next unless claimed

          warn "[AutoGmWatchdog] Recovering orphaned session #{session.id} (last heartbeat: #{session.loop_heartbeat_at || 'never'})"
          Thread.new do
            run_gm_loop(claimed, recovered: true)
          rescue StandardError => e
            warn "[AutoGmWatchdog] Recovery thread crash session #{claimed.id}: #{e.class}: #{e.message}"
            warn e.backtrace.first(5).join("\n")
          end
          recovered += 1
        end

        recovered
      end

      # Find active sessions for a character
      # @param character_instance [CharacterInstance] the character
      # @return [Array<AutoGmSession>] active sessions
      def active_sessions_for(character_instance)
        AutoGmSession
          .where(Sequel.lit('? = ANY(participant_ids)', character_instance.id))
          .where(status: %w[gathering sketching inciting running climax combat])
          .all
      end

      # Find the current active session for a room
      # @param room [Room] the room
      # @return [AutoGmSession, nil]
      def active_session_in_room(room)
        AutoGmSession
          .where(current_room_id: room.id)
          .where(status: %w[gathering sketching inciting running climax combat])
          .first
      end

      # Process an incoming player action
      # Records the action for context — the GM loop handles reactions on its turn.
      # @param session [AutoGmSession] the session
      # @param character_instance [CharacterInstance] who acted
      # @param action_type [String] type of action
      # @param action_data [Hash] action details
      def process_player_action(session, character_instance, action_type, action_data = {})
        return unless session && %w[running climax].include?(session.status)

        # Record the action for context (no immediate LLM response)
        AutoGmAction.create_with_next_sequence(
          session_id: session.id,
          attributes: {
            action_type: 'player_action',
            status: 'completed',
            emit_text: "#{character_instance.character.name}: #{action_data[:description] || action_type}",
            action_data: action_data.merge(
              player_id: character_instance.id,
              player_action_type: action_type
            ),
            target_character_id: character_instance.character_id
          }
        )
      end

      # Process a completed combat
      # @param session [AutoGmSession] the session
      # @param fight [Fight] the completed fight
      # @param result [Symbol] :victory or :defeat
      def process_combat_complete(session, fight, result)
        return unless session

        # Update session status
        session.update(status: 'running', current_fight_id: nil)

        # Adjust chaos based on combat outcome
        AutoGmEventService.adjust_chaos(session, pc_in_control: result == :victory)

        # Get GM response to combat outcome
        situation = result == :victory ?
          'The characters have won the combat.' :
          'The characters have been defeated in combat.'

        response = AutoGmDecisionService.quick_response(session, situation)
        AutoGmActionExecutor.execute(session, response)
      end

      # Notify Auto-GM of a player's IC action (called from BroadcastService)
      # Only records the action — the GM loop handles reactions on its turn.
      # @param room_id [Integer] room where action occurred
      # @param sender_instance [CharacterInstance] who acted
      # @param content [String] the action content
      # @param type [Symbol] message type (:say, :emote, etc.)
      def notify_player_action(room_id:, sender_instance:, content:, type:)
        # Only care about RP-relevant types
        rp_types = %i[say emote pose action narrate]
        return unless rp_types.include?(type)

        # Find active session in this room
        session = active_session_in_room_by_id(room_id)
        return unless session

        # Check sender is a participant (not an NPC or bystander)
        return unless session.participant_ids.include?(sender_instance.id)

        # Strip HTML tags from content before storing — formatted messages contain
        # speech color spans, bold tags etc. that would leak into LLM prompts
        plain_content = strip_html(content)

        # Record as player_action (no LLM call)
        AutoGmAction.create_with_next_sequence(
          session_id: session.id,
          attributes: {
            action_type: 'player_action',
            status: 'completed',
            emit_text: "#{sender_instance.character.name}: #{plain_content[0..200]}",
            action_data: {
              player_id: sender_instance.id,
              player_action_type: type.to_s,
              content: plain_content[0..500]
            },
            target_character_id: sender_instance.character_id
          }
        )
      rescue StandardError => e
        warn "[AutoGmSession] Player action notification failed: #{e.message}"
      end

      # Find active session in a room by room ID
      # @param room_id [Integer] the room ID
      # @return [AutoGmSession, nil]
      def active_session_in_room_by_id(room_id)
        AutoGmSession
          .where(current_room_id: room_id)
          .where(status: %w[running climax combat])
          .first
      end

      private

      # Check if session should continue
      # @param session [AutoGmSession] the session
      # @return [Boolean]
      def should_continue_loop?(session)
        %w[running climax].include?(session.status)
      end

      # Check if session has timed out
      # @param session [AutoGmSession] the session
      # @return [Boolean]
      def session_timed_out?(session)
        last_activity = session.last_action_at || session.started_at || session.created_at
        return false unless last_activity

        Time.now - last_activity > SESSION_TIMEOUT_SECONDS
      end

      # Check if GM should take action, using adaptive pacing
      # @param session [AutoGmSession] the session
      # @return [Boolean]
      def should_gm_act?(session)
        return false unless %w[running climax].include?(session.status)
        return false if session.in_combat?
        return true if session.auto_gm_actions_dataset.empty?

        # Don't act while waiting for a player to roll — give them up to 90s
        if has_pending_roll?(session)
          last_roll_req = session.auto_gm_actions_dataset
            .where(action_type: 'roll_request')
            .order(Sequel.desc(:created_at))
            .first
          return false if last_roll_req && (Time.now - last_roll_req.created_at) < 90
        end

        mode = pacing_mode(session)

        # Get time since last GM action
        last_gm_action = session.auto_gm_actions_dataset
          .exclude(action_type: 'player_action')
          .order(Sequel.desc(:created_at))
          .first

        return true unless last_gm_action

        seconds_since_gm = Time.now - last_gm_action.created_at

        case mode
        when :active
          # Wait for lull — act once nobody is composing and there's been
          # at least a brief pause since last player action
          last_player = session.auto_gm_actions_dataset
            .where(action_type: 'player_action')
            .order(Sequel.desc(:created_at))
            .first

          # All participants have acted since last GM action, or 15s lull
          if last_player && last_player.created_at > last_gm_action.created_at
            all_acted = all_participants_acted_since?(session, last_gm_action.created_at)
            return true if all_acted
            return seconds_since_gm > 15 # Brief lull fallback
          end

          seconds_since_gm > 30 # Fallback if no player actions after GM
        when :quiet
          seconds_since_gm > 60 # Drive narrative every ~60s
        when :stalled
          seconds_since_gm > 180 # Slow cadence for AFK
        end
      end

      # Check if there is a pending roll request with no response yet.
      # The roll_pending flag in action_data is the authoritative signal —
      # AutoGmRollService sets it to false when the player completes the roll.
      # @param session [AutoGmSession]
      # @return [Boolean]
      def has_pending_roll?(session)
        last_roll_req = session.auto_gm_actions_dataset
          .where(action_type: 'roll_request')
          .order(Sequel.desc(:created_at))
          .first
        return false unless last_roll_req

        # Check the authoritative flag set by AutoGmRollService
        data = last_roll_req.action_data || {}
        return false unless data['roll_pending']

        # If the GM already took another action after the roll request, it moved on
        last_gm_action = session.auto_gm_actions_dataset
          .exclude(action_type: %w[player_action roll_request])
          .order(Sequel.desc(:created_at))
          .first
        return false if last_gm_action && last_gm_action.created_at > last_roll_req.created_at

        true
      end

      # Determine current pacing mode based on player activity
      # @param session [AutoGmSession]
      # @return [Symbol] :active, :quiet, or :stalled
      def pacing_mode(session)
        room_id = session.current_room_id

        # Check if anyone is composing RP content (say/emote)
        if anyone_composing_rp?(room_id, session.participant_ids)
          return :active # Someone typing — treat as active, GM should wait
        end

        # Check recent RP-relevant player actions
        last_rp_action = session.auto_gm_actions_dataset
          .where(action_type: 'player_action')
          .order(Sequel.desc(:created_at))
          .first

        if last_rp_action.nil?
          return :quiet # No player actions ever — drive narrative
        end

        seconds_since_action = Time.now - last_rp_action.created_at

        if seconds_since_action < 120   # 2 minutes
          :active
        elsif seconds_since_action < 300 # 5 minutes
          :quiet
        else
          :stalled
        end
      end

      # Check if any participant is composing RP content (say/emote)
      # @param room_id [Integer]
      # @param participant_ids [Array<Integer>]
      # @return [Boolean]
      def anyone_composing_rp?(room_id, participant_ids)
        return false unless defined?(REDIS_POOL) && room_id

        REDIS_POOL.with do |redis|
          typing_ids = redis.smembers("room_typing:#{room_id}")
          typing_ids.each do |char_id|
            next unless participant_ids.include?(char_id.to_i)

            info_json = redis.get("typing:#{room_id}:#{char_id}")
            next unless info_json

            info = JSON.parse(info_json)
            cmd_type = info['command_type']
            status = info['status']

            # Only RP-relevant typing counts (emote/say, not ooc/channel)
            return true if %w[emote say].include?(cmd_type) && status != 'idle'
          end
        end

        false
      rescue StandardError => e
        now = Time.now.to_i
        last_log = Thread.current[:autogm_last_typing_error_log_at]
        if last_log.nil? || (now - last_log) >= 60
          warn "[AutoGmSession] Typing check failed for room #{room_id}: #{e.message}"
          Thread.current[:autogm_last_typing_error_log_at] = now
        end
        false
      end

      # Check if all participants have had a player_action since a given time
      # @param session [AutoGmSession]
      # @param since [Time]
      # @return [Boolean]
      def all_participants_acted_since?(session, since)
        acted_ids = session.auto_gm_actions_dataset
          .where(action_type: 'player_action')
          .where { created_at > since }
          .select_map(Sequel.lit("action_data->>'player_id'"))
          .map(&:to_i)
          .uniq

        (session.participant_ids - acted_ids).empty?
      end

      # Fail a session with an error
      # @param session [AutoGmSession] the session
      # @param error [String] error message
      def fail_session(session, error)
        warn "[AutoGmSession] Pipeline failed for session #{session.id}: #{error}"

        # Store error in world state using a plain Hash to avoid JSONBHash dirty-tracking issues
        state = (session.world_state || {}).to_hash
        state['error'] = error.to_s

        session.update(
          status: 'abandoned',
          resolved_at: Time.now,
          resolution_type: 'abandoned',
          world_state: Sequel.pg_jsonb_wrap(state)
        )

        # Broadcast failure to participants
        room_id = session.current_room_id || session.starting_room_id
        truncated_error = error.to_s.length > 100 ? "#{error.to_s[0..96]}..." : error.to_s
        BroadcastService.to_room(
          room_id,
          {
            content: "The adventure cannot continue... (#{truncated_error})",
            html: "<div class='auto-gm-error'><em>The adventure cannot continue...</em></div>",
            type: 'auto_gm_error'
          },
          type: :auto_gm_error
        ) if defined?(BroadcastService)
      rescue StandardError => e
        warn "[AutoGmSession] Failed to record pipeline error for session #{session.id}: #{e.message}"
      end

      public

      # Check feature toggle for Auto-GM starts
      # @return [Boolean]
      def auto_gm_enabled?
        return true unless defined?(GameSetting)

        raw = GameSetting.get('auto_gm_enabled')
        return true if raw.nil?

        raw == true || raw == 'true' || raw == '1'
      rescue StandardError => e
        warn "[AutoGmSession] Failed to read auto_gm_enabled setting: #{e.message}"
        true
      end

      private

      # Refresh heartbeat only if we still own the loop (atomic check-and-update)
      # @param session [AutoGmSession]
      # @param loop_owner [String]
      def heartbeat!(session, loop_owner)
        updated = AutoGmSession
          .where(id: session.id, loop_owner: loop_owner)
          .update(loop_heartbeat_at: Time.now)

        # If no rows updated, we lost ownership
        if updated == 0
          session.reload
          warn "[AutoGmLoop] Session #{session.id}: heartbeat skipped, ownership lost to #{session.loop_owner}"
        end
      rescue StandardError => e
        warn "[AutoGmLoop] Session #{session.id}: heartbeat update failed: #{e.message}"
      end

      # Clear loop ownership safely
      # @param session [AutoGmSession]
      # @param loop_owner [String]
      def release_loop_ownership(session, loop_owner)
        session.reload
        return unless session.loop_owner == loop_owner

        session.update(loop_owner: nil, loop_heartbeat_at: nil)
      rescue StandardError => e
        warn "[AutoGmLoop] Session #{session.id}: cleanup failed: #{e.message}"
      end
    end
  end
end
