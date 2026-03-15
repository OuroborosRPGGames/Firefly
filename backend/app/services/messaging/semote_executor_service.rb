# frozen_string_literal: true

# SemoteExecutorService executes game commands extracted from smart emotes.
#
# It takes actions from SemoteInterpreterService and runs them through
# the command registry, handling disambiguation and timed actions.
#
class SemoteExecutorService
  # Commands that create timed actions (movement commands)
  # These need special handling as remaining actions should be queued
  TIMED_COMMANDS = %w[walk run jog crawl limp strut meander stroll sneak sprint
                      swagger stride march hike creep shuffle amble trudge wander
                      lumber pad skip plod shamble patrol sashay stalk stomp
                      pace scramble stagger prowl traipse drift travel saunter fly].freeze

  class << self
    # Execute a single action
    # @param character_instance [CharacterInstance]
    # @param command [String]
    # @param target [String, nil]
    # @param emote_text [String] original emote for disambiguation context
    # @param semote_log [SemoteLog, nil] optional log to record execution
    # @return [Hash] { success: Boolean, error: String?, result: Hash? }
    def execute_action(character_instance:, command:, target:, emote_text:, semote_log:)
      # Check blocklist
      if SemoteInterpreterService.blocklisted?(command)
        error = "Command '#{command}' is blocklisted for semote"
        record_execution(semote_log, command: command, target: target, success: false, error: error)
        return { success: false, error: error }
      end

      # Find the command class
      command_class = command_class_for(command)
      unless command_class
        error = "Command '#{command}' not found"
        record_execution(semote_log, command: command, target: target, success: false, error: error)
        return { success: false, error: error }
      end

      # Build the command input string
      input = build_command_input(command, target)

      # Execute the command
      result = execute_command(character_instance, command_class, input, emote_text, semote_log)

      # Record execution
      record_execution(
        semote_log,
        command: command,
        target: target,
        success: result[:success],
        error: result[:error]
      )

      result
    rescue StandardError => e
      warn "[SemoteExecutorService] Error executing '#{command}': #{e.message}"
      error = "Execution error: #{e.message}"
      record_execution(semote_log, command: command, target: target, success: false, error: error)
      { success: false, error: error }
    end

    # Execute multiple actions in sequence
    # @param character_instance [CharacterInstance]
    # @param actions [Array<Hash>] array of { command:, target: }
    # @param emote_text [String]
    # @param semote_log [SemoteLog, nil]
    # @return [Array<Hash>] results for each action
    def execute_actions_sequentially(character_instance:, actions:, emote_text:, semote_log:)
      results = []

      actions.each do |action|
        result = execute_action(
          character_instance: character_instance,
          command: action[:command],
          target: action[:target],
          emote_text: emote_text,
          semote_log: semote_log
        )

        results << result

        # If this was a timed command and succeeded, queue remaining actions
        # The remaining actions will execute when the timed action completes
        if result[:success] && timed_command?(action[:command])
          remaining = actions[actions.index(action) + 1..]
          if remaining&.any?
            queue_remaining_actions(character_instance, remaining, emote_text, semote_log)
            break # Stop processing - remaining actions are queued
          end
        end
      end

      results
    end

    # Find a command class by name
    # @param command_name [String]
    # @return [Class, nil]
    def command_class_for(command_name)
      return nil if SemoteInterpreterService.blocklisted?(command_name)

      command_class, _words_consumed = Commands::Base::Registry.find_command(command_name)
      command_class
    end

    # Check if a command creates a timed action
    # @param command_name [String]
    # @return [Boolean]
    def timed_command?(command_name)
      TIMED_COMMANDS.include?(command_name.to_s.downcase)
    end

    private

    # Build command input string from command and target
    # @param command [String]
    # @param target [String, nil]
    # @return [String]
    def build_command_input(command, target)
      if target && !target.to_s.strip.empty?
        "#{command} #{target}"
      else
        command
      end
    end

    # Execute a command and handle disambiguation
    # @param character_instance [CharacterInstance]
    # @param command_class [Class]
    # @param input [String]
    # @param emote_text [String]
    # @param semote_log [SemoteLog, nil]
    # @return [Hash]
    def execute_command(character_instance, command_class, input, emote_text, semote_log)
      command = command_class.new(character_instance)
      result = command.execute(input)

      # Handle disambiguation (quickmenu response)
      if needs_disambiguation?(result)
        result = handle_disambiguation(
          character_instance: character_instance,
          command_class: command_class,
          original_input: input,
          emote_text: emote_text,
          quickmenu_result: result
        )
      end

      normalize_result(result)
    end

    # Check if result needs disambiguation
    # @param result [Hash]
    # @return [Boolean]
    def needs_disambiguation?(result)
      result[:quickmenu] || result[:type] == :quickmenu
    end

    # Handle disambiguation using LLM
    # @param character_instance [CharacterInstance]
    # @param command_class [Class]
    # @param original_input [String]
    # @param emote_text [String]
    # @param quickmenu_result [Hash]
    # @return [Hash]
    def handle_disambiguation(character_instance:, command_class:, original_input:, emote_text:, quickmenu_result:)
      options = extract_quickmenu_options(quickmenu_result)
      return { success: false, error: 'No disambiguation options available' } if options.empty?

      # Parse original input to get command and target
      parts = original_input.split(' ', 2)
      command = parts[0]
      target = parts[1]

      # Use LLM to disambiguate
      selected = SemoteInterpreterService.disambiguate(emote_text, command, target, options)

      if selected
        # Re-execute with the specific choice
        new_input = "#{command} #{selected}"
        command_instance = command_class.new(character_instance)
        result = command_instance.execute(new_input)
        normalize_result(result)
      else
        { success: false, error: 'Could not disambiguate target' }
      end
    end

    # Extract option labels from quickmenu result
    # @param result [Hash]
    # @return [Array<String>]
    def extract_quickmenu_options(result)
      options = result[:options] || result.dig(:data, :options) || []
      options.map { |opt| opt[:label] || opt['label'] || opt[:name] || opt['name'] }.compact
    end

    # Normalize command result to standard format
    # @param result [Hash]
    # @return [Hash]
    def normalize_result(result)
      if result[:success]
        { success: true, result: result }
      else
        { success: false, error: result[:error] || 'Command failed' }
      end
    end

    # Record execution to semote log
    # @param semote_log [SemoteLog, nil]
    # @param command [String]
    # @param target [String, nil]
    # @param success [Boolean]
    # @param error [String, nil]
    def record_execution(semote_log, command:, target:, success:, error:)
      return unless semote_log

      semote_log.record_execution(
        command: command,
        target: target,
        success: success,
        error: error
      )
    end

    # Queue remaining actions to execute after a timed action completes
    # Stores pending actions in the active TimedAction's action_data
    # @param character_instance [CharacterInstance]
    # @param remaining_actions [Array<Hash>]
    # @param emote_text [String]
    # @param semote_log [SemoteLog, nil]
    def queue_remaining_actions(character_instance, remaining_actions, emote_text, semote_log)
      # Get the most recent active timed action (the walk that was just started)
      timed_actions = TimedAction.active_for_character(character_instance.id)
      timed_action = timed_actions.is_a?(Array) ? timed_actions.last : timed_actions
      unless timed_action
        warn "[SemoteExecutorService] No active timed action found to queue remaining actions"
        return
      end

      # Get current action_data and add semote continuation data
      current_data = timed_action.parsed_action_data
      current_data[:semote_pending_actions] = remaining_actions
      current_data[:semote_emote_text] = emote_text
      current_data[:semote_log_id] = semote_log&.id

      # Update the timed action with new data
      timed_action.update(action_data: current_data.to_json)

      warn "[SemoteExecutorService] Queued #{remaining_actions.length} actions for after timed action ##{timed_action.id}"
    end
  end
end
