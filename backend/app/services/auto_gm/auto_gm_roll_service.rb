# frozen_string_literal: true

module AutoGm
  # AutoGmRollService processes player dice rolls against pending GM requests.
  #
  # This service connects the dice roll system to the Auto-GM loop:
  # - Finds pending roll requests for a character
  # - Evaluates roll results against DC
  # - Records outcomes in action data
  # - Triggers GM responses based on success/failure
  #
  class AutoGmRollService
    class << self
      # Process a player's dice roll against any pending Auto-GM roll requests
      # @param character_instance [CharacterInstance] the character who rolled
      # @param roll_result [DiceRollResult, Hash] the roll result
      # @param stat_used [String] the stat(s) used for the roll
      # @return [Hash] { processed: bool, success: bool, action: AutoGmAction }
      def process_roll(character_instance, roll_result, stat_used)
        # Find active Auto-GM session for this character
        session = find_active_session(character_instance)
        return { processed: false, reason: 'No active Auto-GM session' } unless session

        # Find pending roll request targeting this character
        pending_action = find_pending_roll_request(session, character_instance)
        return { processed: false, reason: 'No pending roll request' } unless pending_action

        # Extract roll total
        total = extract_roll_total(roll_result)
        return { processed: false, reason: 'Could not extract roll total' } unless total

        # Enforce requested stat matching to prevent off-stat roll submissions.
        stat_validation = validate_requested_stat(pending_action.action_data, stat_used)
        unless stat_validation[:ok]
          return {
            processed: false,
            reason: 'Roll stat mismatch',
            expected_stat: stat_validation[:expected_stat]
          }
        end

        # Evaluate against DC
        dc = pending_action.action_data['roll_dc'] || 10
        success = total >= dc
        margin = total - dc

        # Update the action with roll results
        update_action_with_result(pending_action, character_instance, total, success, margin, stat_used)

        # Check if all targets have rolled
        all_complete = check_all_rolls_complete(pending_action)

        # Trigger GM response if all rolls are in
        if all_complete
          trigger_gm_response(session, pending_action)
        end

        {
          processed: true,
          success: success,
          total: total,
          dc: dc,
          margin: margin,
          action: pending_action,
          all_complete: all_complete
        }
      end

      # Find pending roll requests for a session (for debugging/inspection)
      # @param session [AutoGmSession] the session
      # @return [Array<AutoGmAction>] pending roll requests
      def pending_roll_requests(session)
        session.auto_gm_actions_dataset
          .where(action_type: 'roll_request')
          .where(Sequel.pg_jsonb_op(:action_data).contains({ 'roll_pending' => true }))
          .all
      end

      private

      # Find the active Auto-GM session for a character
      # @param character_instance [CharacterInstance] the character
      # @return [AutoGmSession, nil]
      def find_active_session(character_instance)
        AutoGmSession
          .where(status: %w[running climax])
          .where(Sequel.lit('? = ANY(participant_ids)', character_instance.id))
          .first
      end

      # Find a pending roll request targeting this character
      # @param session [AutoGmSession] the session
      # @param character_instance [CharacterInstance] the character
      # @return [AutoGmAction, nil]
      def find_pending_roll_request(session, character_instance)
        # Get all pending roll requests
        pending_requests = session.auto_gm_actions_dataset
          .where(action_type: 'roll_request')
          .where(status: 'completed')  # Action was executed but roll_pending is still true
          .order(Sequel.desc(:created_at))
          .all

        # Find one that targets this character and hasn't been resolved
        pending_requests.find do |action|
          data = action.action_data || {}
          next false unless data['roll_pending']

          # Check if this character is a target
          targets = data['roll_targets'] || []
          next false unless targets.include?(character_instance.id)

          # Check if this character hasn't already rolled
          results = data['roll_results'] || {}
          !results.key?(character_instance.id.to_s)
        end
      end

      # Extract roll total from result
      # @param roll_result [DiceRollResult, Hash] the roll result
      # @return [Integer, nil]
      def extract_roll_total(roll_result)
        if roll_result.respond_to?(:total)
          roll_result.total
        elsif roll_result.is_a?(Hash)
          roll_result[:total] || roll_result['total']
        else
          nil
        end
      end

      # Validate that the provided stat string matches the requested roll stat.
      # Requires an exact single-stat match when a roll_stat_id exists.
      #
      # @param action_data [Hash]
      # @param stat_used [String]
      # @return [Hash] { ok: Boolean, expected_stat: String|nil }
      def validate_requested_stat(action_data, stat_used)
        data = action_data || {}
        requested_stat_id = data['roll_stat_id']
        return { ok: true, expected_stat: nil } unless requested_stat_id

        requested_stat = Stat[requested_stat_id]
        return { ok: true, expected_stat: nil } unless requested_stat

        used_names = stat_used.to_s.split(/[+,\s]+/).map(&:strip).reject(&:empty?).map(&:downcase)
        expected_names = [requested_stat.name, requested_stat.abbreviation].compact.map(&:downcase)
        matched = used_names.length == 1 && expected_names.include?(used_names.first)

        { ok: matched, expected_stat: requested_stat.name }
      end

      # Update action with roll result
      # @param action [AutoGmAction] the roll request action
      # @param character_instance [CharacterInstance] who rolled
      # @param total [Integer] roll total
      # @param success [Boolean] whether roll met/exceeded DC
      # @param margin [Integer] how much above/below DC
      # @param stat_used [String] the stat(s) used
      def update_action_with_result(action, character_instance, total, success, margin, stat_used)
        # Deep-dup via JSON round-trip to ensure Sequel detects the change
        # (shallow .dup shares nested hash references, breaking dirty tracking)
        data = JSON.parse((action.action_data || {}).to_json)
        data['roll_results'] ||= {}

        char_name = DisplayHelper.character_display_name(character_instance)

        stat_check = validate_requested_stat(data, stat_used)
        stat_matched = stat_check[:ok]

        data['roll_results'][character_instance.id.to_s] = {
          'character_name' => char_name,
          'total' => total,
          'success' => success,
          'margin' => margin,
          'stat_used' => stat_used,
          'stat_matched' => stat_matched,
          'rolled_at' => Time.now.iso8601
        }

        # Check if all targets have rolled
        targets = data['roll_targets'] || []
        results = data['roll_results'] || {}
        all_rolled = targets.all? { |t| results.key?(t.to_s) }

        if all_rolled
          data['roll_pending'] = false
          data['roll_completed_at'] = Time.now.iso8601

          # Calculate aggregate success
          successes = results.values.count { |r| r['success'] }
          failures = results.values.count { |r| !r['success'] }
          data['aggregate_success'] = successes > failures
          data['success_count'] = successes
          data['failure_count'] = failures
        end

        action.update(action_data: data)
      end

      # Check if all targeted characters have rolled
      # @param action [AutoGmAction] the roll request action
      # @return [Boolean]
      def check_all_rolls_complete(action)
        data = action.action_data || {}
        !data['roll_pending']
      end

      # Trigger GM response to completed roll
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the completed roll request
      def trigger_gm_response(session, action)
        data = action.action_data || {}
        roll_type = data['roll_type'] || 'skill check'
        aggregate_success = data['aggregate_success']
        results = data['roll_results'] || {}

        # Build context for GM response
        result_descriptions = results.map do |_char_id, result|
          outcome = result['success'] ? 'succeeded' : 'failed'
          "#{result['character_name']} #{outcome} (rolled #{result['total']} vs DC #{data['roll_dc']})"
        end.join('; ')

        # Create situation description for GM
        situation = if aggregate_success
          "The characters succeeded at the #{roll_type}. Results: #{result_descriptions}"
        else
          "The characters failed at the #{roll_type}. Results: #{result_descriptions}"
        end

        # Get GM response
        if defined?(AutoGm::AutoGmDecisionService)
          response = AutoGm::AutoGmDecisionService.quick_response(session, situation)
          AutoGm::AutoGmActionExecutor.execute(session, response) if response
        end

        # Adjust chaos based on outcome
        if defined?(AutoGm::AutoGmEventService)
          AutoGm::AutoGmEventService.adjust_chaos(session, pc_in_control: aggregate_success)
        end

        # Broadcast roll summary to participants
        broadcast_roll_summary(session, action, data)
      end

      # Broadcast roll summary to session participants
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the roll action
      # @param data [Hash] action data with results
      def broadcast_roll_summary(session, action, data)
        results = data['roll_results'] || {}
        roll_type = data['roll_type'] || 'check'
        dc = data['roll_dc']
        aggregate = data['aggregate_success']

        # Build summary message
        summary_parts = results.map do |_char_id, result|
          marker = result['success'] ? 'SUCCESS' : 'FAIL'
          "#{marker} #{result['character_name']}: #{result['total']}"
        end

        outcome_text = aggregate ? 'SUCCESS' : 'FAILURE'
        plain = "#{roll_type.capitalize} (DC #{dc}): #{outcome_text} - #{summary_parts.join(' | ')}"
        escaped_parts = summary_parts.map { |p| ERB::Util.html_escape(p) }
        html = "<div class='auto-gm-roll-summary #{aggregate ? 'success' : 'failure'}'><strong>#{ERB::Util.html_escape(roll_type.capitalize)} (DC #{ERB::Util.html_escape(dc.to_s)}):</strong> #{ERB::Util.html_escape(outcome_text)}<br>#{escaped_parts.join(' &middot; ')}</div>"

        room_id = session.current_room_id || session.starting_room_id
        BroadcastService.to_room(
          room_id,
          {
            content: plain,
            html: html,
            type: 'auto_gm_roll_summary'
          },
          type: :auto_gm_roll_summary
        )
      end
    end
  end
end
