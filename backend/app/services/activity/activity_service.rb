# frozen_string_literal: true

class ActivityService
  class ActivityError < StandardError; end
  class NotAllowedError < ActivityError; end
  class NotFoundError < ActivityError; end
  class InvalidStateError < ActivityError; end

  # Reference centralized config for input timeout
  INPUT_TIMEOUT_SECONDS = GameConfig::Activity::TIMEOUTS[:input_seconds]
  POST_RESOLUTION_DELAYS = {
    'branch' => 15,
    'rest' => 15,
    'free_roll' => 30,
    'persuade' => 30
  }.freeze

  class << self
    # Start a new activity instance
    def start_activity(activity, room:, initiator:, event: nil)
      raise NotFoundError, 'Activity not found' unless activity
      launch_mode = activity.launch_mode
      if launch_mode && !launch_mode.to_s.strip.empty?
        # Legacy activities may still use creator mode with no creator set.
        if launch_mode == 'creator' && activity.created_by.nil?
          # Allow launch through for backward compatibility.
        elsif !activity.can_be_launched_by?(initiator.character, room: room)
          raise NotAllowedError, 'You cannot start this activity here'
        end
      elsif activity.location && activity.location != room.id
        raise NotAllowedError, 'This activity is not available in this room'
      end

      # Check if there's already a running instance in this room
      existing = ::ActivityInstance.where(
        room_id: room.id,
        running: true
      ).first

      raise InvalidStateError, 'Activity is already running in this room' if existing

      instance = ::ActivityInstance.create(
        activity_id: activity.id,
        room_id: room.id,
        event_id: event&.id,
        initiator_id: initiator.character_id,
        atype: activity.atype,
        team_name_one: activity.team_name_one,
        team_name_two: activity.team_name_two,
        setup_stage: 2,
        rounds_done: 0,
        branch: 0,
        running: true,
        last_round: Time.now,
        round_started_at: Time.now,
        ActivityInstance::HOLD_TIMER_COLUMN => ActivityInstance::HOLD_TIMER_CLEARED
      )

      # Add initiator as participant
      add_participant(instance, initiator)

      # Broadcast to room
      broadcast_activity_start(instance, initiator)

      # Note: quickmenu for the initiator is handled by the start_activity command
      # which calls create_quickmenu directly in the HTTP response. Pushing here
      # would create a duplicate stored interaction.

      instance
    end

    # Add a participant to an activity
    def add_participant(instance, character_instance, team: nil, role: nil)
      raise InvalidStateError, 'Activity is not running' unless instance.running?

      # Check if already participating
      existing = instance.participants_dataset.where(char_id: character_instance.character_id).first
      return existing if existing

      participant = ::ActivityParticipant.create(
        instance_id: instance.id,
        activity_parent: instance.activity_id,
        char_id: character_instance.character_id,
        team: team,
        role: role,
        score: 0.0,
        willpower: ActivityParticipant::MAX_WILLPOWER,
        willpower_ticks: ActivityParticipant::MAX_WILLPOWER,
        continue: true
      )
      # Set willpower_to_spend to NULL via raw update (model setter converts nil to 0)
      ::ActivityParticipant.where(id: participant.id).update(willpower_to_spend: nil)
      participant.reload
    end

    # Remove participant from activity
    def remove_participant(participant)
      instance = participant.instance
      participant.update(continue: false)
      broadcast_participant_left(participant)

      return participant unless instance&.running?
      return participant unless instance.active_participants.count.zero?

      BroadcastService.to_room(
        instance.room_id,
        'The activity ends because all participants have left.',
        type: :activity_end,
        data: { instance_id: instance.id }
      )

      complete_activity(instance, success: false)
      participant
    end

    # Submit participant choice
    def submit_choice(participant, action_id:, risk: nil, target_id: nil, willpower: 0)
      raise InvalidStateError, 'You are not in an active activity' unless participant.active?

      instance = participant.instance
      raise InvalidStateError, 'Activity is not waiting for input' unless instance.running?

      participant.submit_choice!(
        action_id: action_id,
        risk: risk,
        target_id: target_id,
        willpower: willpower
      )

      # Don't auto-resolve here — wait for players to 'activity ready'
      # so they have time to add willpower dice first

      participant
    end

    # Check if ready to resolve and do so if appropriate
    def check_all_ready(instance)
      return unless instance
      return unless instance.running?
      process_pending_round_transition(instance)
      return if instance.post_resolution_hold_pending?
      round = instance.current_round
      return if manually_resolved_round?(round)

      if instance.all_ready? || instance.input_timed_out?
        resolve_round(instance)
      end
    end

    # Resolve the current round
    def resolve_round(instance)
      round = instance.current_round
      return unless round
      return if instance.post_resolution_hold_pending?

      # Use round-type-specific resolution rules where available.
      result = resolve_round_typed(instance)
      return result if round.combat?
      return unless result
      normalized = normalize_round_result(result, round)

      # Record the result
      record_round_result(instance, round, normalized)

      # Award willpower
      award_round_willpower(instance)

      # Broadcast animated dice rolls (before narrative)
      dice_duration_ms = broadcast_activity_dice(instance, normalized)
      normalized[:dice_duration_ms] = dice_duration_ms

      # Broadcast result before any round transition so clients stay in sync.
      broadcast_round_result(instance, round, normalized)

      # Emit observer effect messages and clear actions for next round
      emit_observer_effects(instance)

      # Advance or handle failure
      if normalized[:success]
        advance_to_next_round(instance, round)
      else
        skip_consequence = round.reflex? || round.group_check?
        handle_round_failure(instance, round, skip_consequence: skip_consequence)
      end

      normalized
    end

    # Advance to the next round
    def advance_to_next_round(instance, current_round)
      # Check mission triggers for round completion
      TriggerService.check_mission_triggers(
        activity_instance: instance,
        event_type: 'round_complete',
        round: current_round.round_number
      )

      next_round = current_round.next_round

      # Stop media if current round's duration_mode is 'round'
      if current_round.has_media? && current_round.media_stops_on_round_end?
        stop_activity_media(instance)
      end

      # If no next round in current branch, try rejoining the main branch
      if next_round.nil? && instance.branch != 0
        activity = instance.activity
        next_round_number = current_round.round_number + 1
        next_round = activity.round_at(next_round_number, 0)

        if next_round
          # Rejoin main branch
          instance.update(
            branch: 0,
            rounds_done: next_round_number - 1,
            last_round: Time.now,
            round_started_at: Time.now,
            ActivityInstance::HOLD_TIMER_COLUMN => ActivityInstance::HOLD_TIMER_CLEARED
          )
          instance.reset_participant_choices!
          set_participant_options(instance)
          broadcast_round_start(instance)
          push_quickmenus_to_participants(instance)
          auto_resolve_if_mandatory(instance)
          return
        end
      end

      if next_round
        instance.advance_round!
        set_participant_options(instance)
        broadcast_round_start(instance)
        push_quickmenus_to_participants(instance)
        auto_resolve_if_mandatory(instance)
      else
        complete_activity(instance, success: true)
      end
    end

    # Handle round failure
    def handle_round_failure(instance, round, skip_consequence: false)
      if round.can_fail_repeat?
        # Repeat the same round
        instance.update(round_repeated: (instance.round_repeated || 0) + 1)
        instance.reset_participant_choices!
        instance.start_round_timer!
        broadcast_round_retry(instance, round)
      elsif round.branch? && round.reverts_to_main?
        # Revert to main branch
        instance.switch_branch!(0)
        instance.advance_round!
        set_participant_options(instance)
        broadcast_branch_change(instance, 0)
      elsif round.knockout
        # Knockout failure - end the activity
        complete_activity(instance, success: false)
      else
        if !skip_consequence && round.fail_consequence_type == 'branch' && round.fail_branch_to
          # fail_branch_to is an ActivityRound ID, so branch by jumping directly.
          advance_with_branch(instance, round.fail_branch_to)
          return
        end

        # Apply failure consequence and continue
        apply_failure_consequence(instance, round) unless skip_consequence
        advance_to_next_round(instance, round)
      end
    end

    # Apply failure consequence without ending the activity
    def apply_failure_consequence(instance, round)
      case round.fail_consequence_type
      when 'difficulty'
        # Increase difficulty for future rounds
        instance.update(inc_difficulty: (instance.inc_difficulty || 0) + 2)
      when 'injury'
        # Apply injury to all participants
        instance.active_participants.each do |p|
          p.update(injured: true)
        end
      when 'harder_finale'
        # Make the finale more difficult
        instance.update(finale_modifier: (instance.finale_modifier || 0) + 3)
      end
      # 'none' - no consequence, just continue
    end

    # Switch to a different branch
    def switch_branch(instance, new_branch)
      instance.switch_branch!(new_branch)
      set_participant_options(instance)
      broadcast_branch_change(instance, new_branch)

      # Check mission triggers for branch change
      TriggerService.check_mission_triggers(
        activity_instance: instance,
        event_type: 'branch',
        branch: new_branch
      )
    end

    # Advance to the next round (public method for use by round-specific services)
    def advance_round(instance)
      round = instance.current_round
      return unless round

      advance_to_next_round(instance, round)
    end

    # Delay configured round types between solve and transition.
    # Returns hold-until Time when queued, or nil when no delay applies.
    def queue_post_resolution_transition(instance, round, delay_seconds: nil)
      return nil unless instance && round
      return nil unless instance.running?

      delay = delay_seconds.nil? ? post_resolution_delay_seconds(round) : delay_seconds.to_i
      return nil unless delay.positive?

      if instance.post_resolution_hold_pending?
        return instance.post_resolution_hold_until
      end

      hold_until = instance.queue_post_resolution_hold!(delay)

      BroadcastService.to_room(
        instance.room_id,
        "Round resolved. Continuing in #{delay} seconds...",
        type: :activity_round_wait,
        data: {
          instance_id: instance.id,
          round_number: instance.current_round_number,
          delay_seconds: delay,
          hold_until: hold_until.iso8601
        }
      )

      hold_until
    rescue StandardError => e
      warn "[ActivityService] Failed to queue delayed transition: #{e.message}"
      nil
    end

    # Process delayed transition if it is due.
    # Returns :advanced, :waiting, :none, or :error.
    def process_pending_round_transition(instance)
      return :none unless instance
      return :none unless instance.running?

      timeout_state = process_timed_out_branch_round(instance)
      return timeout_state unless timeout_state == :none

      return :none unless instance.post_resolution_hold_pending?
      return :waiting unless instance.post_resolution_hold_due?

      round = instance.current_round
      unless round
        instance.clear_post_resolution_hold!
        return :none
      end

      round_type = round.round_type.to_s

      case round_type
      when 'branch'
        result = ActivityBranchService.resolve(instance, round)
        instance.clear_post_resolution_hold!
        advance_with_branch(instance, result.chosen_branch_id)
      when 'rest'
        instance.clear_post_resolution_hold!
        instance.reset_continue_votes!
        advance_round(instance)
      when 'free_roll', 'persuade'
        instance.clear_post_resolution_hold!
        advance_round(instance)
      else
        instance.clear_post_resolution_hold!
        advance_round(instance)
      end

      :advanced
    rescue StandardError => e
      warn "[ActivityService] Failed to process delayed transition: #{e.message}"
      :error
    end

    # Resolve timed-out branch rounds that have not yet been resolved.
    # Returns :advanced, :waiting, :none, or :error.
    def process_timed_out_branch_round(instance)
      round = instance.current_round
      return :none unless round&.branch?
      return :none unless instance.input_timed_out?
      return :none if instance.post_resolution_hold_pending?

      result = ActivityBranchService.resolve(instance, round)
      chosen_text = result.respond_to?(:chosen_branch_text) ? result.chosen_branch_text : 'a path'
      chosen_id = result.respond_to?(:chosen_branch_id) ? result.chosen_branch_id : nil

      BroadcastService.to_room(
        instance.room_id,
        "Branch vote timed out. The group chose: #{chosen_text}",
        type: :activity_branch,
        data: {
          instance_id: instance.id,
          chosen_branch_id: chosen_id,
          chosen_branch_text: chosen_text
        }
      )

      hold_until = queue_post_resolution_transition(instance, round)
      return :waiting if hold_until

      advance_with_branch(instance, chosen_id)
      :advanced
    rescue StandardError => e
      warn "[ActivityService] Failed to process timed-out branch round: #{e.message}"
      :error
    end

    def post_resolution_delay_seconds(round)
      return 0 unless round

      POST_RESOLUTION_DELAYS.fetch(round.round_type.to_s, 0)
    end

    # Advance with a specific branch (for branch rounds)
    def advance_with_branch(instance, target_round_id)
      target_round = ::ActivityRound[target_round_id]
      if target_round && target_round.activity_id != instance.activity_id
        warn "[ActivityService] Ignoring cross-activity branch target #{target_round_id} for instance #{instance.id}"
        target_round = nil
      end

      unless target_round
        # No target round - just advance normally (stays on main branch)
        advance_round(instance)
        return
      end

      # Jump directly to the target round by setting branch and rounds_done
      # rounds_done = round_number - 1 so current_round returns target_round
      instance.update(
        branch: target_round.branch,
        rounds_done: target_round.round_number - 1,
        last_round: Time.now,
        round_started_at: Time.now,
        ActivityInstance::HOLD_TIMER_COLUMN => ActivityInstance::HOLD_TIMER_CLEARED
      )
      instance.reset_participant_choices!
      set_participant_options(instance)
      broadcast_round_start(instance)
      push_quickmenus_to_participants(instance)
      auto_resolve_if_mandatory(instance)
    end

    # Resolve a round with type-specific handling
    def resolve_round_typed(instance)
      round = instance.current_round
      return unless round

      result = case round.round_type
               when 'reflex'
                 ActivityReflexService.resolve(instance, round)
               when 'group_check'
                 ActivityGroupCheckService.resolve(instance, round)
               when 'branch'
                 # Branch rounds resolved by voting
                 nil
               when 'rest'
                 # Rest rounds resolved by vote to continue
                 nil
               when 'free_roll'
                 # Free-roll rounds resolve through assess/action commands.
                 nil
               when 'persuade'
                 # Persuade rounds resolve through the persuade command.
                 nil
               when 'combat'
                 ActivityCombatService.start_combat(instance, round)
               else
                 ActivityResolutionService.resolve(instance, round)
               end

      result
    end

    # Complete the activity
    def complete_activity(instance, success: true, broadcast: true)
      instance.complete!(success: success)
      award_completion_rewards(instance, success)
      stop_activity_media(instance)
      broadcast_activity_complete(instance, success) if broadcast

      # Check mission triggers for completion
      TriggerService.check_mission_triggers(
        activity_instance: instance,
        event_type: success ? 'succeed' : 'fail'
      )
    end

    # Get available activities for a room
    # Excludes anchor-mode activities (those are launched via items, not listed)
    def available_activities(room)
      base = Activity.where(is_public: true)
                     .where(Sequel.|({ launch_mode: nil }, Sequel.~(launch_mode: 'anchor')))

      return base.all unless room

      base.where(Sequel.|({ location: room.id }, { location: nil }))
          .all
    end

    # Get running activity in a room
    def running_activity(room)
      return nil unless defined?(::ActivityInstance)

      ::ActivityInstance.where(room_id: room.id, running: true).first
    end

    # Get participant for a character in an activity
    def participant_for(instance, character_instance)
      instance.participant_for(character_instance)
    end

    # Push activity quickmenus to all active participants via WebSocket + Redis.
    # Only applies to round types that use quickmenus (standard, reflex, group_check).
    def push_quickmenus_to_participants(instance)
      round = instance.current_round
      return unless round

      # Only push quickmenus for round types that use action selection
      return if round.persuade? || round.free_roll? || round.rest? || round.branch? || round.combat?

      instance.active_participants.each do |participant|
        char_instance = participant.character_instance
        next unless char_instance&.online

        begin
          menu_data = ActivityQuickmenuHandler.show_menu(participant, char_instance)
          next unless menu_data

          interaction_id = SecureRandom.uuid
          stored = {
            interaction_id: interaction_id,
            type: 'quickmenu',
            prompt: menu_data[:prompt],
            options: menu_data[:options],
            context: menu_data[:context] || {},
            created_at: Time.now.iso8601
          }
          OutputHelper.store_agent_interaction(char_instance, interaction_id, stored)

          BroadcastService.to_character(
            char_instance,
            { content: 'Choose your action for this round.' },
            type: :quickmenu,
            data: {
              interaction_id: interaction_id,
              prompt: menu_data[:prompt],
              options: menu_data[:options]
            }
          )
        rescue StandardError => e
          warn "[ActivityService] Failed to push quickmenu to participant #{participant.id}: #{e.message}"
        end
      end
    end

    # Broadcast a participant's choice immediately for coordination
    def broadcast_participant_choice(participant, instance)
      return unless instance

      char_name = participant.character&.full_name || 'Someone'
      task = participant.chosen_task
      action = participant.chosen_action

      text = if task && action
               "#{char_name} commits to #{task.description}: #{action.choice_text}"
             elsif task
               "#{char_name} moves to work on #{task.description}"
             elsif participant.helping?
               target_name = participant.target_participant&.character&.full_name || 'another player'
               "#{char_name} is helping #{target_name}"
             elsif participant.recovering?
               "#{char_name} is taking a breather"
             elsif action
               "#{char_name} chooses: #{action.choice_text}"
             end

      return unless text

      BroadcastService.to_room(
        instance.room_id,
        text,
        type: :activity_choice,
        data: {
          instance_id: instance.id,
          participant_id: participant.id,
          task_id: task&.id,
          action_id: action&.id
        }
      )
    rescue StandardError => e
      warn "[ActivityService] Failed to broadcast participant choice: #{e.message}"
    end

    # Emit observer messages and clear queued actions at round end.
    # Used by round flows that don't route through resolve_round.
    def finalize_observer_effects(instance)
      emit_observer_effects(instance)
    end

    private

    def manually_resolved_round?(round)
      return false unless round

      %w[branch rest free_roll persuade].include?(round.round_type.to_s)
    end

    def normalize_round_result(result, round)
      return result if result.is_a?(Hash)

      if result.respond_to?(:participant_rolls)
        return result.to_h
      end

      if result.respond_to?(:participant_results)
        rolls = result.participant_results.map do |pr|
          {
            participant_id: pr.respond_to?(:participant_id) ? pr.participant_id : nil,
            character_name: pr.respond_to?(:character_name) ? pr.character_name : 'Unknown',
            action_type: 'option',
            action_name: round.round_type,
            total: pr.respond_to?(:roll_total) ? pr.roll_total : (pr.respond_to?(:total) ? pr.total : 0)
          }
        end

        return {
          success: result.respond_to?(:success) ? result.success : false,
          participant_rolls: rolls
        }
      end

      { success: false, participant_rolls: [] }
    end

    # Mandatory-roll rounds (reflex, group_check) wait for players to use
    # 'activity ready' — they don't auto-resolve. The mark_ready handler
    # auto-sets action_chosen for these round types.
    def auto_resolve_if_mandatory(_instance)
      # No-op: players trigger resolution via 'activity ready'
    end

    # Set available action options for all participants based on current round
    def set_participant_options(instance)
      round = instance.current_round
      return unless round

      action_ids = round.action_ids

      instance.active_participants.each do |participant|
        # Filter by role if applicable
        available = filter_actions_by_role(action_ids, participant.role)
        participant.update(action_options: available)
      end
    end

    def filter_actions_by_role(action_ids, role)
      return action_ids if StringHelper.blank?(role)
      return action_ids if action_ids.nil? || action_ids.empty?

      ActivityAction.where(id: action_ids).all.select do |action|
        action.available_to_role?(role)
      end.map(&:id)
    end

    # Start media for a round using the shared MediaSyncService
    def start_round_media(instance, round)
      return unless round.has_media?
      return unless round.youtube?

      video_id = round.extract_youtube_video_id(round.media_url)
      return unless video_id

      # Get a host character instance (first active participant)
      host = instance.active_participants.first&.character_instance
      return unless host

      MediaSyncService.start_youtube(
        room_id: instance.room_id,
        host: host,
        video_id: video_id,
        title: "Activity: #{instance.activity.display_name}"
      )
    rescue StandardError => e
      warn "[ActivityService] Failed to start round media: #{e.message}"
    end

    # Stop media when round/activity ends
    def stop_activity_media(instance)
      MediaSyncService.end_room_session(instance.room_id)
    rescue StandardError => e
      warn "[ActivityService] Failed to stop activity media: #{e.message}"
    end

    # Award willpower at end of round
    def award_round_willpower(instance)
      # Gain 0.5 willpower every round (matching plan spec)
      # In Ravencroft, willpower_ticks are used for recovery
      instance.active_participants.each do |p|
        current = p.available_willpower
        new_willpower = [current + 1, ActivityParticipant::MAX_WILLPOWER].min
        p.update(willpower: new_willpower)
      end
    end

    # Record round result to the activity log
    def record_round_result(instance, round, result)
      ActivityLoggingService.log_round_end(instance, round, {
        summary: result[:success] ? (round.success_text || 'Success!') : (round.failure_text || 'Failed!'),
        participants: (result[:participant_rolls] || []).map do |roll|
          {
            name: roll.respond_to?(:character_name) ? roll.character_name : 'Unknown',
            roll: roll.respond_to?(:total) ? roll.total : nil,
            outcome: roll.respond_to?(:action_type) ? roll.action_type : 'option',
            result: roll.respond_to?(:total) ? "Roll: #{roll.total}" : nil
          }
        end
      })
    rescue StandardError => e
      warn "[ActivityService] Failed to record round result: #{e.message}"
    end

    # Award rewards on completion
    def award_completion_rewards(instance, success)
      return unless success

      activity = instance.activity

      # Command XP reward
      if activity.command_reward && activity.command_reward > 0
        instance.active_participants.each do |p|
          char = p.character
          # Award command XP if applicable
        end
      end

      # Resource rewards
      if activity.resource_type && activity.resource_amount && activity.resource_amount > 0
        instance.active_participants.each do |p|
          # Award resources
        end
      end
    end

    # Broadcast methods
    def broadcast_activity_start(instance, initiator)
      message = "#{initiator.character&.full_name} has started '#{instance.activity.display_name}'!"

      BroadcastService.to_room(
        instance.room_id,
        message,
        type: :activity_start,
        data: { instance_id: instance.id, activity_name: instance.activity.display_name }
      )

      # Log to story
      IcActivityService.record(
        room_id: instance.room_id, content: message,
        sender: initiator, type: :activity
      )
    end

    def broadcast_round_start(instance)
      round = instance.current_round
      return unless round

      # Persuade attempts are tracked per-round.
      instance.reset_persuade_attempts! if round.persuade? && instance.persuade_attempts.to_i.positive?

      emit = round.emit_text || "Round #{instance.current_round_number} begins."

      data = {
        instance_id: instance.id,
        round_number: instance.current_round_number,
        round_type: round.round_type
      }

      if ActivityTextSubstitutionService.has_tokens?(emit)
        broadcast_substituted_text(instance, emit, type: :activity_round, data: data)
      else
        BroadcastService.to_room(instance.room_id, emit, type: :activity_round, data: data)
      end

      # Log narrative emit text to story (only custom emit text, not generic "Round N begins")
      if round.emit_text
        IcActivityService.record(
          room_id: instance.room_id, content: emit,
          sender: nil, type: :activity
        )
      end

      # Notify remote observers of round start
      notify_observers_round_start(instance, round)

      # Start media session if round has media configured
      start_round_media(instance, round)
    end

    def broadcast_round_result(instance, round, result)
      text = result[:success] ? (round.success_text || 'Success!') : (round.failure_text || 'Failed!')

      dice_ms = result[:dice_duration_ms] || 0

      data = {
        instance_id: instance.id,
        round_number: instance.current_round_number,
        success: result[:success],
        rolls: result[:participant_rolls] || result.participant_rolls,
        dice_duration_ms: dice_ms
      }

      if ActivityTextSubstitutionService.has_tokens?(text)
        broadcast_substituted_text(instance, text, type: :activity_result, data: data)
      else
        BroadcastService.to_room(instance.room_id, text, type: :activity_result, data: data)
      end

      # Log custom round result text to story
      custom_text = result[:success] ? round.success_text : round.failure_text
      if custom_text
        IcActivityService.record(
          room_id: instance.room_id, content: text,
          sender: nil, type: :activity
        )
      end
    end

    def broadcast_round_retry(instance, round)
      BroadcastService.to_room(
        instance.room_id,
        round.failure_consequence || 'The group must try again...',
        type: :activity_retry,
        data: { instance_id: instance.id }
      )
    end

    def broadcast_branch_change(instance, new_branch)
      BroadcastService.to_room(
        instance.room_id,
        "The activity takes a different path...",
        type: :activity_branch,
        data: { instance_id: instance.id, branch: new_branch }
      )
    end

    def broadcast_activity_complete(instance, success)
      activity = instance.activity
      text = success ? (activity.last_string || 'Activity completed!') : 'Activity failed.'

      BroadcastService.to_room(
        instance.room_id,
        text,
        type: :activity_complete,
        data: {
          instance_id: instance.id,
          success: success,
          activity_name: activity.display_name
        }
      )

      # Log completion to story
      IcActivityService.record(
        room_id: instance.room_id, content: text,
        sender: nil, type: :activity
      )
    end

    def broadcast_participant_left(participant)
      instance = participant.instance
      return unless instance

      BroadcastService.to_room(
        instance.room_id,
        "#{participant.character&.full_name} has left the activity.",
        type: :activity_leave,
        data: { instance_id: instance.id }
      )
    end

    # Broadcast activity text with per-viewer name/pronoun substitution
    def broadcast_substituted_text(instance, text, type:, data: {}, **metadata)
      room_chars = CharacterInstance.where(
        current_room_id: instance.room_id, online: true
      ).eager(:character).all

      # Get the first active participant's character for token resolution
      participant = instance.active_participants.first
      acting_character = participant&.character

      unless acting_character
        # Fallback: broadcast without substitution
        BroadcastService.to_room(instance.room_id, text, type: type, data: data, **metadata)
        return
      end

      room_chars.each do |viewer|
        personalized = ActivityTextSubstitutionService.substitute(
          text,
          character: acting_character,
          viewer: viewer
        )

        BroadcastService.to_character(
          viewer,
          personalized,
          type: type,
          data: data,
          **metadata
        )
      end
    rescue StandardError => e
      warn "[ActivityService] Failed to broadcast substituted text: #{e.message}"
      # Fallback to room broadcast
      BroadcastService.to_room(instance.room_id, text, type: type, data: data, **metadata)
    end

    # Broadcast dice roll animations for activity round resolution.
    # Returns the max animation duration in ms for delaying narrative.
    def broadcast_activity_dice(instance, result)
      rolls = if result.respond_to?(:participant_rolls)
                result.participant_rolls
              else
                result[:participant_rolls]
              end
      return 0 unless rolls&.any?

      dice_duration_ms = 0

      room_chars = CharacterInstance.where(
        current_room_id: instance.room_id, online: true
      ).eager(:character).all

      rolls.each do |roll|
        next unless roll.respond_to?(:animation_data) && roll.animation_data
        next if roll.action_type == 'help' || roll.action_type == 'recover'

        # Calculate duration
        dur = DiceRollService.calculate_animation_duration_ms(roll.animation_data)
        dice_duration_ms = dur if dur > dice_duration_ms

        # Broadcast to each viewer with personalized name
        room_chars.each do |viewer|
          participant = instance.active_participants.detect { |p| p.id == roll.participant_id }
          char = participant&.character
          viewer_name = char ? (char.display_name_for(viewer) || roll.character_name) : roll.character_name

          # Replace character name in animation data for this viewer
          viewer_anim = roll.animation_data.sub(/\A[^|]+/, viewer_name)

          BroadcastService.to_character(
            viewer,
            {
              type: 'dice_roll',
              character_id: roll.participant_id,
              # character_name omitted — already embedded in animation_data
              # (including it causes the JS to show the name twice)
              animation_data: viewer_anim,
              roll_modifier: roll.stat_bonus || 0,
              roll_total: roll.total,
              timestamp: Time.now.iso8601
            },
            type: :dice_roll
          )
        end
      end

      # Add 1s buffer (matches combat handler pattern)
      dice_duration_ms += 1000 if dice_duration_ms > 0
      dice_duration_ms
    rescue StandardError => e
      warn "[ActivityService] Failed to broadcast activity dice: #{e.message}"
      0
    end

    # ========================================
    # Remote Observer Integration
    # ========================================

    # Emit observer effect messages to room and observers, then clear actions
    def emit_observer_effects(instance)
      return unless instance

      # Get formatted messages from observers who took actions
      observer_messages = ObserverEffectService.emit_observer_messages(instance)

      observer_messages.each do |msg|
        # Broadcast to the room so participants see the effects
        BroadcastService.to_room(
          instance.room_id,
          msg,
          type: :observer_effect,
          data: { instance_id: instance.id }
        )

        # Also send to remote observers so they see their effects applied
        instance.broadcast_to_observers(msg)

        # Log observer effects to story
        IcActivityService.record(
          room_id: instance.room_id, content: msg,
          sender: nil, type: :activity
        )
      end

      # Clear observer actions for next round
      ObserverEffectService.clear_actions!(instance)
    rescue StandardError => e
      warn "[ActivityService] Failed to emit observer effects: #{e.message}"
    end

    public

    # Called by the scheduler to resolve all timed-out activity rounds.
    def resolve_timed_out_instances!
      resolved = 0
      errors = []

      ActivityInstance.where(running: true).each do |instance|
        next unless instance.input_timed_out?(INPUT_TIMEOUT_SECONDS)

        begin
          resolve_round(instance)
          resolved += 1
        rescue StandardError => e
          errors << { instance_id: instance.id, error: e.message }
        end
      end

      puts "[Activity] Resolved #{resolved} timed-out activity round(s)" if resolved > 0
      errors.each { |err| warn "[Activity] Error for instance ##{err[:instance_id]}: #{err[:error]}" }
    end

    # Notify remote observers when a new round starts
    def notify_observers_round_start(instance, round)
      return unless instance
      return unless round

      emit = round.emit_text || "Round #{instance.current_round_number} begins."
      message = "Round #{instance.current_round_number} starting: #{emit}"

      instance.broadcast_to_observers(message)
    rescue StandardError => e
      warn "[ActivityService] Failed to notify observers of round start: #{e.message}"
    end
  end
end
