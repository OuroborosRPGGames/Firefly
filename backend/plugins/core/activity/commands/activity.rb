# frozen_string_literal: true

module Commands
  module Activity
    # Main command for managing activities.
    # Supports listing, starting, joining, leaving, and checking status of activities.
    class Activity < Commands::Base::Command
      command_name 'activity'
      aliases 'act', 'mission', 'task'
      category :events
      help_text 'Manage activities, missions, and tasks'
      usage 'activity <subcommand> [arguments]'
      examples(
        'activity list',
        'activity start Heist',
        'activity join',
        'activity leave',
        'activity status',
        'activity choose 1',
        'activity help Bob',
        'activity recover',
        'activity vote 1',
        'activity heal',
        'activity continue',
        'activity assess look around',
        'activity action pick the lock',
        'activity persuade',
        'activity accept Bob',
        'activity reject Bob'
      )
      requires :character

      # Alias for location (used throughout this command)
      def room
        location
      end

      def perform_command(parsed_input)
        args = parsed_input[:args]
        subcommand = args.first&.downcase
        sub_args = args[1..] || []
        sync_pending_transition unless %w[list ls start begin].include?(subcommand)

        case subcommand
        when 'list', 'ls'
          list_activities
        when 'start', 'begin'
          start_activity(sub_args)
        when 'join', 'enter'
          join_activity
        when 'leave', 'quit', 'exit'
          leave_activity
        when 'status', 'stat', 'info'
          show_status
        when 'choose', 'pick', 'select'
          choose_action(sub_args)
        when 'help'
          help_another(sub_args)
        when 'recover', 'rest'
          do_recover
        when 'effort', 'willpower', 'wp'
          set_effort(sub_args)
        when 'ready', 'done'
          mark_ready
        # New round type commands
        when 'vote'
          vote_branch(sub_args)
        when 'heal'
          heal_at_rest
        when 'continue'
          vote_continue
        when 'assess'
          do_assess(sub_args)
        when 'action'
          do_action(sub_args)
        when 'persuade'
          do_persuade
        when 'accept'
          delegate_to_observe(['accept'] + sub_args)
        when 'reject', 'deny'
          delegate_to_observe(['reject'] + sub_args)
        else
          show_usage
        end
      end

      private

      # List available activities
      def list_activities
        activities = ActivityService.available_activities(room)

        if activities.empty?
          return success_result('No activities are currently available.')
        end

        lines = ['Available Activities:']
        activities.each_with_index do |act, idx|
          type_label = act.atype || 'mission'
          lines << "  #{idx + 1}. #{act.display_name} [#{type_label}]"
          lines << "     #{act.adesc}" if act.adesc
        end

        success_result(lines.join("\n"), type: :message)
      end

      # Start an activity
      def start_activity(args)
        name = args.join(' ')

        if name.empty?
          return error_result('Usage: activity start <activity name>')
        end

        # Find activity by name or number
        activity = find_activity(name)

        unless activity
          return error_result("Activity '#{name}' not found. Use 'activity list' to see available activities.")
        end

        # Check if there's already a running activity in the room
        existing = ActivityService.running_activity(room)
        if existing
          lines = [
            "There's already an activity running in this room: #{existing.activity.display_name}",
            "You can 'activity join' to participate or wait for it to finish."
          ]
          return error_result(lines.join("\n"))
        end

        # Start the activity
        instance = ActivityService.start_activity(activity, room: room, initiator: character_instance)

        lines = [
          "You have started '#{activity.display_name}'!",
          "Other players can 'activity join' to participate.",
          "Use 'activity status' to see the current round."
        ]

        # Try to return quickmenu data for the initiator
        round = instance.current_round
        if round
          participant = ActivityService.participant_for(instance, character_instance)
          menu_data = participant ? ActivityQuickmenuHandler.show_menu(participant, character_instance) : nil

          if menu_data
            return create_quickmenu(
              character_instance,
              menu_data[:prompt],
              menu_data[:options],
              context: menu_data[:context] || {}
            )
          end

          # Fallback: text-based action list
          lines << ''
          lines << 'Available Actions:'
          lines.concat(format_available_actions(round))
        end

        success_result(lines.join("\n"), type: :message, data: { instance_id: instance.id })
      rescue ActivityService::ActivityError => e
        error_result(e.message)
      end

      # Join the current activity in the room
      def join_activity
        instance = ActivityService.running_activity(room)

        unless instance
          return error_result("There is no activity running in this room.\nUse 'activity start <name>' to begin one.")
        end

        if instance.has_participant?(character_instance)
          return error_result('You are already participating in this activity.')
        end

        participant = ActivityService.add_participant(instance, character_instance)

        lines = [
          "You have joined '#{instance.activity.display_name}'!",
          "Use 'activity status' to see the current round."
        ]

        # Try to return quickmenu data for the joiner
        round = instance.current_round
        if round
          menu_data = ActivityQuickmenuHandler.show_menu(participant, character_instance)

          if menu_data
            return create_quickmenu(
              character_instance,
              menu_data[:prompt],
              menu_data[:options],
              context: menu_data[:context] || {}
            )
          end

          # Fallback: text-based action list
          lines << ''
          lines << 'Available Actions:'
          lines.concat(format_available_actions(round))
        end

        success_result(lines.join("\n"), type: :message, data: { instance_id: instance.id })
      end

      # Leave the current activity
      def leave_activity
        participant = find_my_participant

        unless participant
          return error_result('You are not participating in any activity.')
        end

        ActivityService.remove_participant(participant)
        success_result('You have left the activity.')
      end

      # Show current activity status
      def show_status
        instance = ActivityService.running_activity(room)

        unless instance
          return error_result('There is no activity running in this room.')
        end

        transition_state = ActivityService.process_pending_round_transition(instance)
        if transition_state == :advanced
          instance = ActivityService.running_activity(room)
          return error_result('There is no activity running in this room.') unless instance
        end

        activity = instance.activity
        round = instance.current_round

        lines = [
          "Activity: #{activity.display_name}",
          "Type: #{activity.atype || 'mission'}",
          "Progress: Round #{instance.current_round_number} of #{instance.total_rounds}",
          "Status: #{instance.status_text}",
          ''
        ]

        if round
          lines << "Current Round: #{round.display_name}"
          if round.emit_text
            emit = ActivityTextSubstitutionService.substitute(
              round.emit_text, character: character, viewer: character_instance
            )
            lines << emit
          end
          lines << ''
        end

        if instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          remaining = instance.respond_to?(:post_resolution_hold_remaining_seconds) ? instance.post_resolution_hold_remaining_seconds : 0
          lines << "Next round starts in: #{remaining} second#{remaining == 1 ? '' : 's'}"
          lines << ''
        end

        # Show participants
        lines << 'Participants:'
        instance.participants.each do |p|
          char = p.character
          status = p.status_text
          wp = p.available_willpower
          lines << "  - #{char&.full_name || 'Unknown'}: #{status} (WP: #{wp})"
        end

        # Show my current choices if participating
        participant = find_my_participant
        if participant
          lines << ''
          lines << 'Your choices:'

          if participant.has_chosen?
            action = participant.chosen_action
            lines << "  Action: #{action&.choice_text || 'Set'}"
            wp = participant.willpower_to_spend.to_i
            lines << "  Willpower dice: #{wp}" if wp > 0
          else
            lines << '  Not yet chosen. Use commands below to make your selection.'
          end

          if round
            lines << ''
            lines.concat(format_available_actions(round))
          end
        end

        success_result(lines.join("\n"), type: :message)
      end

      # Choose an action by number or name
      def choose_action(args)
        participant = find_my_participant

        unless participant
          return error_result('You are not participating in any activity.')
        end

        unless participant.active?
          return error_result('You have already made your choice for this round.')
        end

        instance = participant.instance
        round = instance.current_round

        unless round
          return error_result('There is no active round.')
        end

        # Find the action
        choice = args.join(' ')
        if choice.empty?
          lines = ["Usage: activity choose <action>\nAvailable actions:"]
          lines.concat(format_available_actions(round))
          return error_result(lines.join("\n"))
        end

        action = find_action(round, choice)

        unless action
          lines = ['Invalid action. Available actions:']
          lines.concat(format_available_actions(round))
          return error_result(lines.join("\n"))
        end

        # Auto-set task_chosen if action belongs to a task
        if action.respond_to?(:task_id) && action[:task_id]
          participant.update(task_chosen: action[:task_id]) if participant.respond_to?(:task_chosen=)
        end

        # Submit the choice
        ActivityService.submit_choice(
          participant,
          action_id: action.id
        )

        lines = [
          "You chose: #{action.choice_text}",
          "Use 'activity willpower <0-2>' to add willpower dice, or 'activity ready' when done."
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Help another player
      def help_another(args)
        participant, err = require_active_participant

        return err if err

        target_name = args.join(' ')

        if target_name.empty?
          return error_result('Usage: activity help <player name>')
        end

        instance = participant.instance
        round = instance.respond_to?(:current_round) ? instance.current_round : nil

        if round && ((round.respond_to?(:mandatory_roll?) && round.mandatory_roll?) ||
                     (round.respond_to?(:combat?) && round.combat?) ||
                     ((round.respond_to?(:reflex?) && round.reflex?) ||
                      (round.respond_to?(:group_check?) && round.group_check?)))
          round_name = round.respond_to?(:round_type) ? round.round_type : 'mandatory'
          return error_result("Help is not available for #{round_name} rounds.\nUse 'activity ready' to roll.")
        end

        # Find target participant by name
        target = instance.participants.find do |p|
          next if p.id == participant.id

          char = p.character
          char && (char.full_name.downcase.include?(target_name.downcase) ||
                   char.name.downcase.include?(target_name.downcase))
        end

        unless target
          lines = ["Could not find participant '#{target_name}'.", 'Available participants:']
          instance.participants.each do |p|
            next if p.id == participant.id
            lines << "  - #{p.character&.full_name}"
          end
          return error_result(lines.join("\n"))
        end

        # Submit help choice
        participant.update(
          effort_chosen: 'help',
          action_target: target.id,
          action_chosen: 0,
          chosen_when: Time.now
        )

        # Trigger resolution check
        instance = participant.instance
        ActivityService.check_all_ready(instance)

        lines = [
          "You will help #{target.character&.full_name} this round.",
          "They will roll with advantage thanks to your assistance!"
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Recover willpower
      def do_recover
        instance = ActivityService.running_activity(room)
        participant = instance ? ActivityService.participant_for(instance, character_instance) : nil

        unless participant
          return error_result('You are not participating in any activity.')
        end
        if participant.is_a?(ActivityParticipant) && !participant.active?
          return error_result('You are not an active participant in this activity.')
        end

        round = instance.respond_to?(:current_round) ? instance.current_round : nil
        if round && ((round.respond_to?(:reflex?) && round.reflex?) ||
                     (round.respond_to?(:group_check?) && round.group_check?) ||
                     (round.respond_to?(:free_roll?) && round.free_roll?))
          round_name = round.respond_to?(:round_type) ? round.round_type : 'mandatory'
          return error_result("Recovery is not available for #{round_name} rounds.\nUse 'activity ready' to roll.")
        end

        participant.update(
          effort_chosen: 'recover',
          action_chosen: 0,
          chosen_when: Time.now
        )

        # Trigger resolution check if instance supports it
        ActivityService.check_all_ready(instance) if instance.respond_to?(:running?)

        lines = [
          'You are recovering this round.',
          'You will skip your roll but gain willpower.'
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Set willpower dice to spend
      def set_effort(args)
        participant, err = require_active_participant

        return err if err

        level = args.first

        unless %w[0 1 2].include?(level)
          lines = [
            'Usage: activity willpower <0-2>',
            '  0 = No extra dice',
            '  1 = Spend 1 willpower for +1d8',
            '  2 = Spend 2 willpower for +2d8'
          ]
          return error_result(lines.join("\n"))
        end

        wp_cost = level.to_i
        if wp_cost > participant.available_willpower
          return error_result("You don't have enough willpower.\nAvailable willpower: #{participant.available_willpower}")
        end

        participant.update(willpower_to_spend: wp_cost)
        if wp_cost > 0
          success_result("You will spend #{wp_cost} willpower for +#{wp_cost}d8.", type: :message)
        else
          success_result('You will not spend any willpower dice.', type: :message)
        end
      end

      # Mark as ready
      def mark_ready
        instance = ActivityService.running_activity(room)
        participant = instance ? ActivityService.participant_for(instance, character_instance) : nil

        unless participant
          return error_result('You are not participating in any activity.')
        end
        if participant.is_a?(ActivityParticipant) && !participant.active?
          return error_result('You are not an active participant in this activity.')
        end

        # Don't allow readying during combat — combat 'done' command takes priority
        if instance.paused_for_combat?
          return error_result('Activity is paused for combat. Finish the fight first!')
        end

        # For reflex/group_check/combat rounds, auto-set action if not already chosen
        round = instance.respond_to?(:current_round) ? instance.current_round : nil
        auto_set = round && !participant.has_chosen? &&
                   ((round.respond_to?(:mandatory_roll?) && round.mandatory_roll?) ||
                    (round.respond_to?(:combat?) && round.combat?))
        if auto_set
          attrs = { action_chosen: 0, chosen_when: Time.now }
          # Auto-assign to first task if round has tasks
          if round.respond_to?(:has_tasks?) && round.has_tasks?
            first_task = round.tasks.first
            attrs[:task_chosen] = first_task.id if first_task
          end
          participant.update(attrs)
        end

        unless participant.has_chosen?
          return error_result("You must choose an action first.\nUse 'activity choose <action>' or 'activity help <player>' or 'activity recover'.")
        end

        # Mark as having emoted (for the emote requirement)
        participant.update(has_emoted: true) if participant.respond_to?(:has_emoted=)

        # Check if all participants are ready
        ActivityService.check_all_ready(instance)

        success_result('You are ready for this round!', type: :message)
      end

      # ========================================
      # Branch Round Commands
      # ========================================

      # Vote for a branch choice
      def vote_branch(args)
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.branch?
          return error_result('This round is not a branch round.')
        end

        if instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          return success_result(pending_transition_message(instance), type: :message)
        end

        if participant.has_voted_branch?
          return error_result('You have already voted for this branch round.')
        end

        choice = args.first
        choices = round.expanded_branch_choices

        if choice.nil? || choice.empty?
          lines = ['Available choices:']
          choices.each_with_index do |c, idx|
            lines << "  #{idx + 1}. #{c[:text]}"
            lines << "     #{c[:description]}" if c[:description]
          end
          lines << ''
          lines << "Use 'activity vote <number>' to vote."
          return success_result(lines.join("\n"), type: :message)
        end

        # Find choice by number
        idx = choice.to_i - 1
        if idx < 0 || idx >= choices.length
          return error_result("Invalid choice. Use 'activity vote' to see options.")
        end

        selected = choices[idx]
        # Votes are tracked by option index, not by target round ID.
        vote_key = idx + 1

        ActivityBranchService.submit_vote(participant, vote_key)
        lines = ["You voted for: #{selected[:text]}"]

        # Check if voting is complete
        if ActivityBranchService.voting_complete?(instance)
          result = ActivityBranchService.resolve(instance, round)
          lines << "The group chose: #{result.chosen_branch_text}"
          hold_until = ActivityService.queue_post_resolution_transition(instance, round)
          if hold_until
            lines << pending_transition_message(instance)
          else
            ActivityService.advance_with_branch(instance, result.chosen_branch_id)
          end
        else
          votes = instance.branch_votes
          total = instance.active_participants.count
          lines << "Votes: #{votes.values.sum}/#{total}"
        end

        success_result(lines.join("\n"), type: :message)
      end

      # ========================================
      # Rest Round Commands
      # ========================================

      # Heal at rest
      def heal_at_rest
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.rest?
          return error_result('This round is not a rest round.')
        end

        result = ActivityRestService.heal_at_rest(participant)

        lines = []
        if result.healed_amount > 0
          lines << "You rest and recover #{result.healed_amount} HP."
          lines << "Current HP: #{result.new_hp}/#{result.max_hp}"
          if result.permanent_damage > 0
            lines << "(#{result.permanent_damage} damage is permanent from this mission)"
          end
        else
          lines << 'You are already at maximum recoverable HP.'
          lines << "Current HP: #{result.new_hp}/#{result.max_hp}"
        end

        success_result(lines.join("\n"), type: :message)
      end

      # Vote to continue from rest
      def vote_continue
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.rest?
          return error_result('This round is not a rest round.')
        end

        if instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          return success_result(pending_transition_message(instance), type: :message)
        end

        if participant.voted_continue?
          return error_result('You have already voted to continue.')
        end

        ActivityRestService.vote_to_continue(participant)
        lines = ['You are ready to continue.']

        # Check if majority wants to continue
        if ActivityRestService.ready_to_continue?(instance)
          lines << 'The group is ready!'
          hold_until = ActivityService.queue_post_resolution_transition(instance, round)
          if hold_until
            lines << pending_transition_message(instance)
          else
            instance.reset_continue_votes!
            ActivityService.advance_round(instance)
          end
        else
          status = ActivityRestService.rest_status(instance)
          lines << "Votes to continue: #{status[:continue_votes]}/#{status[:total_participants]}"
        end

        success_result(lines.join("\n"), type: :message)
      end

      # ========================================
      # Free Roll Round Commands (LLM-based)
      # ========================================

      # Assess the situation
      def do_assess(args)
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.free_roll?
          return error_result('This round does not support assess actions.')
        end

        unless ActivityFreeRollService.enabled?
          return error_result('Free roll rounds are not enabled on this server.')
        end

        description = args.join(' ')
        if description.empty?
          return error_result("Usage: activity assess <what you want to learn>\nExample: activity assess look for guards")
        end

        result = ActivityFreeRollService.assess!(participant, description, round)

        if result
          lines = [
            "Stat tested: #{result.stat_names.join(', ')}",
            "DC: #{result.dc}",
            '',
            result.context_revealed
          ]
          success_result(lines.join("\n"), type: :message)
        else
          error_result('Unable to assess. The GM could not determine how to evaluate that.')
        end
      rescue ActivityFreeRollService::FreeRollError => e
        error_result(e.message)
      rescue StandardError => e
        warn "[ActivityCommand] Free roll assess failed: #{e.message}"
        error_result('Unable to assess right now. Please try again.')
      end

      # Take an action in free roll
      def do_action(args)
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.free_roll?
          return error_result('This round does not support action commands.')
        end

        if instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          return success_result(pending_transition_message(instance), type: :message)
        end

        unless ActivityFreeRollService.enabled?
          return error_result('Free roll rounds are not enabled on this server.')
        end

        description = args.join(' ')
        if description.empty?
          return error_result("Usage: activity action <what you want to do>\nExample: activity action pick the lock")
        end

        result = ActivityFreeRollService.take_action(participant, description, round)

        lines = [
          "Stats tested: #{result.stat_names.join(', ')}",
          "Roll: #{result.roll_total} vs DC #{result.dc}",
          result.success ? 'SUCCESS!' : 'FAILED!',
          '',
          result.narration
        ]

        # Check if round is complete
        completion = ActivityFreeRollService.check_round_complete(instance, round)
        if completion[:complete]
          lines << ''
          lines << 'Round complete!'
          already_waiting = instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          hold_until = ActivityService.queue_post_resolution_transition(instance, round)
          if hold_until
            ActivityService.finalize_observer_effects(instance) unless already_waiting
            lines << pending_transition_message(instance)
          else
            ActivityService.finalize_observer_effects(instance)
            ActivityService.advance_round(instance)
          end
        end

        success_result(lines.join("\n"), type: :message)
      rescue ActivityFreeRollService::FreeRollError => e
        error_result(e.message)
      rescue StandardError => e
        warn "[ActivityCommand] Free roll action failed: #{e.message}"
        error_result('Unable to resolve that action right now. Please try again.')
      end

      # ========================================
      # Persuade Round Commands (LLM-based)
      # ========================================

      # Attempt persuasion roll
      def do_persuade
        participant, err = require_active_participant

        return err if err

        instance = participant.instance
        round = instance.current_round

        unless round&.persuade?
          return error_result('This round is not a persuade round.')
        end

        if instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          return success_result(pending_transition_message(instance), type: :message)
        end

        unless ActivityPersuadeService.enabled?
          return error_result('Persuade rounds are not enabled on this server.')
        end

        result = ActivityPersuadeService.attempt_persuasion(participant, instance, round)

        lines = [
          "Roll: #{result.roll_total} vs DC #{result.dc}",
          '',
          "#{round.persuade_npc_name}: #{result.npc_response}",
          ''
        ]

        if result.success
          lines << 'SUCCESS! You convinced them!'
          already_waiting = instance.respond_to?(:post_resolution_hold_pending?) && instance.post_resolution_hold_pending?
          hold_until = ActivityService.queue_post_resolution_transition(instance, round)
          if hold_until
            ActivityService.finalize_observer_effects(instance) unless already_waiting
            lines << pending_transition_message(instance)
          else
            ActivityService.finalize_observer_effects(instance)
            ActivityService.advance_round(instance)
          end
        else
          lines << "Attempt #{result.attempts_made} failed. Continue the conversation and try again."
        end

        success_result(lines.join("\n"), type: :message)
      rescue ActivityPersuadeService::PersuadeError => e
        error_result(e.message)
      rescue StandardError => e
        warn "[ActivityCommand] Persuade failed: #{e.message}"
        error_result('Unable to resolve persuasion right now. Please try again.')
      end

      # Delegate to the observe command for accept/reject subcommands
      def delegate_to_observe(args)
        observe_cmd = Commands::Activity::Observe.new
        observe_cmd.context = context
        observe_cmd.perform_command({ args: args })
      end

      # Show usage information
      def show_usage
        lines = [
          'Activity Commands:',
          '  activity list              - List available activities',
          '  activity start <name>      - Start an activity',
          '  activity join              - Join the current activity',
          '  activity leave             - Leave the activity',
          '  activity status            - Show activity status',
          '  activity choose <action>   - Choose an action',
          '  activity help <player>     - Help another player',
          '  activity recover           - Skip roll, gain willpower',
          '  activity willpower <0-2>   - Set willpower dice to spend',
          '  activity ready             - Mark yourself as ready',
          '',
          'Round-specific commands:',
          '  activity vote <choice>     - Vote for a branch (branch rounds)',
          '  activity heal              - Heal at rest (rest rounds)',
          '  activity continue          - Vote to continue (rest rounds)',
          '  activity assess <desc>     - Assess situation (free roll rounds)',
          '  activity action <desc>     - Take action (free roll rounds)',
          '  activity persuade          - Attempt persuasion (persuade rounds)',
          '',
          'Observer request responses:',
          '  activity accept <player>   - Accept a remote observer request',
          '  activity reject <player>   - Reject a remote observer request'
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Helper methods

      def find_activity(name)
        activities = ActivityService.available_activities(room)

        # Try to find by number
        if name =~ /^\d+$/
          idx = name.to_i - 1
          return activities[idx] if idx >= 0 && idx < activities.length
        end

        # Find by name (case-insensitive partial match)
        activities.find do |a|
          a.aname&.downcase&.include?(name.downcase) ||
            a.display_name&.downcase&.include?(name.downcase)
        end
      end

      def find_action(round, choice)
        actions = round.respond_to?(:all_actions) ? round.all_actions : round.available_actions

        # Try by number
        if choice =~ /^\d+$/
          idx = choice.to_i - 1
          return actions[idx] if idx >= 0 && idx < actions.length
        end

        # Find by name
        actions.find do |a|
          a.choice_text&.downcase&.include?(choice.downcase)
        end
      end

      def find_my_participant
        instance = ActivityService.running_activity(room)
        return nil unless instance

        ActivityService.process_pending_round_transition(instance)
        instance.reload if instance.respond_to?(:reload)

        ActivityService.participant_for(instance, character_instance)
      end

      # Returns [participant, nil] on success or [nil, error_result] on failure.
      # Use as: participant, err = require_active_participant; return err if err
      def require_active_participant
        participant = find_my_participant
        return [nil, error_result('You are not participating in any activity.')] unless participant
        if participant.is_a?(ActivityParticipant) && !participant.active?
          return [nil, error_result('You are not an active participant in this activity.')]
        end

        [participant, nil]
      end

      def sync_pending_transition
        instance = ActivityService.running_activity(room)
        return unless instance

        ActivityService.process_pending_round_transition(instance)
      rescue StandardError => e
        warn "[ActivityCommand] Pending transition sync failed: #{e.message}"
      end

      def pending_transition_message(instance)
        remaining = if instance.respond_to?(:post_resolution_hold_remaining_seconds)
                      instance.post_resolution_hold_remaining_seconds
                    else
                      0
                    end
        "Round resolved. Continuing in #{remaining} second#{remaining == 1 ? '' : 's'}..."
      end

      def format_available_actions(round)
        lines = []

        # Determine round type using respond_to? for compatibility
        round_type = if round.respond_to?(:round_type)
                       round.round_type
                     elsif round.respond_to?(:branch?) && round.branch?
                       'branch'
                     else
                       'standard'
                     end

        case round_type
        when 'branch'
          choices = round.expanded_branch_choices
          choices.each_with_index do |choice, idx|
            lines << "  #{idx + 1}. #{sub_tokens(choice[:text])}"
            lines << "     #{sub_tokens(choice[:description])}" if choice[:description]
          end
          lines << ''
          lines << "Use 'activity vote <number>' to vote for your choice"
        when 'persuade'
          lines << "Use 'activity persuade' to attempt persuasion"
          lines << "Or: 'activity recover' to skip and gain willpower"
        when 'free_roll'
          lines << "Use 'activity action <description>' to take an action"
          lines << "    'activity assess <approach>' to scout first (optional)"
          lines << "Or: 'activity recover' to skip and gain willpower"
        when 'rest'
          lines << "Use 'activity heal' to recover HP"
          lines << "    'activity continue' to vote to move on"
        when 'reflex'
          stat_name = round.respond_to?(:reflex_stat_name) ? round.reflex_stat_name : 'Agility'
          lines << "Reflex check! Testing #{stat_name}."
          lines << "Use 'activity ready' to roll."
        when 'group_check'
          lines << "Group check! Everyone must roll."
          lines << "Use 'activity ready' to roll."
        when 'combat'
          npc_count = round.respond_to?(:combat_npc_ids) ? (round.combat_npc_ids&.length || 0) : 0
          lines << "Combat round! #{npc_count} #{npc_count == 1 ? 'enemy' : 'enemies'} await."
          lines << "Difficulty: #{round.respond_to?(:combat_difficulty) ? (round.combat_difficulty || 'normal') : 'normal'}"
          lines << "Use 'activity ready' to begin the fight."
        else
          actions = round.respond_to?(:all_actions) ? round.all_actions : round.available_actions
          actions.each_with_index do |action, idx|
            lines << "  #{idx + 1}. #{sub_tokens(action.choice_text)}"
          end
          lines << ''
          lines << "Or: 'activity help <player>' to assist someone"
          lines << "    'activity recover' to skip and gain willpower"
        end
        lines
      end

      # Substitute activity text tokens for the current character
      def sub_tokens(text)
        return text unless text

        ActivityTextSubstitutionService.substitute(text, character: character, viewer: character_instance)
      end
    end
  end
end

# REQUIRED: Register with the command registry
Commands::Base::Registry.register(Commands::Activity::Activity)
