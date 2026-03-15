# frozen_string_literal: true

# Handles branch round resolution for the Activity System.
#
# Branch rounds are decision points where:
# - Present 2-3 branch choices with descriptions
# - Each participant votes for a branch
# - Resolution: When majority have voted OR timeout
# - Majority vote wins; ties broken by first to reach majority
# - No dice rolling
class ActivityBranchService
  class BranchError < StandardError; end

  # Result structure for branch round
  BranchResult = Struct.new(
    :chosen_branch_id,
    :chosen_branch_text,
    :vote_counts,       # Hash of branch_id => count
    :total_votes,
    :emit_text,
    :result_text,
    keyword_init: true
  )

  class << self
    # Resolve a branch round based on votes
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The branch round to resolve
    # @return [BranchResult]
    def resolve(instance, round)
      raise BranchError, 'Not a branch round' unless round.branch?
      raise BranchError, 'No active participants' if instance.active_participants.empty?

      choices = round.expanded_branch_choices
      raise BranchError, 'No branch choices defined' if choices.empty?

      votes = instance.branch_votes
      total_votes = votes.values.sum

      # Find winning choice by vote key (1-based option index)
      winning_choice_index = nil
      winning_count = 0
      winning_text = nil

      choices.each_with_index do |choice, idx|
        vote_key = idx + 1
        count = votes[vote_key] || 0

        if count > winning_count
          winning_count = count
          winning_choice_index = idx
          winning_text = choice[:text]
        end
      end

      # Handle no votes (timeout with no votes - pick first choice)
      winning_choice_index = 0 if winning_choice_index.nil? && choices.any?
      chosen_target_round_id = choices[winning_choice_index]&.dig(:branch_to_round_id)
      winning_text = choices[winning_choice_index]&.dig(:text) if winning_text.nil?

      BranchResult.new(
        chosen_branch_id: chosen_target_round_id,
        chosen_branch_text: winning_text,
        vote_counts: votes,
        total_votes: total_votes,
        emit_text: round.emit_text,
        result_text: "The group chose: #{winning_text}"
      )
    end

    # Submit a vote from a participant
    # @param participant [ActivityParticipant]
    # @param branch_id [Integer] The branch choice index or ID
    # @return [Boolean] Success
    def submit_vote(participant, branch_id)
      participant.vote_for_branch!(branch_id)
      true
    end

    # Check if voting is complete (majority or all voted)
    # @param instance [ActivityInstance]
    # @return [Boolean]
    def voting_complete?(instance)
      !instance.majority_branch_vote.nil? || instance.all_voted_branch?
    end

    # Get available choices for display
    # @param round [ActivityRound]
    # @return [Array<Hash>] Array of { id:, text:, description: }
    def available_choices(round)
      round.expanded_branch_choices.each_with_index.map do |choice, idx|
        {
          id: idx + 1,
          text: choice[:text],
          description: choice[:description]
        }
      end
    end
  end
end
