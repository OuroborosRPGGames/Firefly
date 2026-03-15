# frozen_string_literal: true

# SemoteContinuationHandler continues smartemote action sequences
# after a timed action (like walk) completes.
#
# When a semote triggers a walk followed by other actions (sit, etc.),
# the pending actions are stored in the TimedAction's action_data.
# This handler picks them up and continues execution.
#
class SemoteContinuationHandler
  class << self
    def call(timed_action)
      data = timed_action.parsed_action_data
      pending_actions = data[:semote_pending_actions]

      return unless pending_actions.is_a?(Array) && pending_actions.any?

      character_instance = timed_action.character_instance
      return unless character_instance

      # Refresh to get latest state after movement
      character_instance.refresh

      emote_text = data[:semote_emote_text] || ''
      semote_log = data[:semote_log_id] ? SemoteLog[data[:semote_log_id]] : nil

      # Normalize pending actions (they may have string keys from JSON)
      normalized_actions = pending_actions.map do |a|
        { command: a[:command] || a['command'], target: a[:target] || a['target'] }
      end

      SemoteExecutorService.execute_actions_sequentially(
        character_instance: character_instance,
        actions: normalized_actions,
        emote_text: emote_text,
        semote_log: semote_log
      )
    rescue StandardError => e
      warn "[SemoteContinuationHandler] Error: #{e.message}"
    end
  end
end
