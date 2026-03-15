# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityBranchService do
  let(:activity) { create(:activity) }
  let(:room) { create(:room) }
  let(:instance) do
    create(:activity_instance, activity: activity, room: room, running: true)
  end
  let(:branch_round) { create(:activity_round, :branch, activity: activity, round_number: 1) }
  let(:standard_round) { create(:activity_round, :standard, activity: activity, round_number: 2) }
  let(:character) { create(:character) }
  let(:participant) do
    create(:activity_participant, instance: instance, character: character)
  end

  describe 'error classes' do
    it 'defines BranchError' do
      expect(described_class::BranchError).to be < StandardError
    end
  end

  describe 'BranchResult struct' do
    it 'has expected attributes' do
      result = described_class::BranchResult.new(
        chosen_branch_id: 1,
        chosen_branch_text: 'Option A',
        vote_counts: { 1 => 3 },
        total_votes: 3,
        emit_text: 'Description',
        result_text: 'The group chose: Option A'
      )
      expect(result.chosen_branch_id).to eq(1)
      expect(result.chosen_branch_text).to eq('Option A')
      expect(result.vote_counts).to eq({ 1 => 3 })
    end
  end

  describe '.resolve' do
    it 'raises BranchError for non-branch round' do
      expect {
        described_class.resolve(instance, standard_round)
      }.to raise_error(described_class::BranchError, /Not a branch round/)
    end

    it 'raises BranchError when no active participants' do
      # Remove all participants
      instance.participants_dataset.delete

      expect {
        described_class.resolve(instance, branch_round)
      }.to raise_error(described_class::BranchError, /No active participants/)
    end

    it 'resolves votes by option index and returns the choice target round id' do
      round = double('ActivityRound',
                     branch?: true,
                     emit_text: 'Choose a path',
                     expanded_branch_choices: [
                       { text: 'Left', branch_to_round_id: 101, description: nil },
                       { text: 'Right', branch_to_round_id: 202, description: nil }
                     ])
      mock_instance = double('ActivityInstance',
                             active_participants: [double('P1'), double('P2')],
                             branch_votes: { 2 => 1 })

      result = described_class.resolve(mock_instance, round)

      expect(result.chosen_branch_id).to eq(202)
      expect(result.chosen_branch_text).to eq('Right')
    end

    it 'allows winning choices without a target round id' do
      round = double('ActivityRound',
                     branch?: true,
                     emit_text: 'Choose a path',
                     expanded_branch_choices: [
                       { text: 'Stay on course', branch_to_round_id: nil, description: nil },
                       { text: 'Detour', branch_to_round_id: 303, description: nil }
                     ])
      mock_instance = double('ActivityInstance',
                             active_participants: [double('P1'), double('P2')],
                             branch_votes: { 1 => 1 })

      result = described_class.resolve(mock_instance, round)

      expect(result.chosen_branch_id).to be_nil
      expect(result.chosen_branch_text).to eq('Stay on course')
    end
  end

  describe '.submit_vote' do
    before do
      participant # ensure participant exists
    end

    it 'records the vote' do
      # This tests the interface; actual vote recording depends on model method
      result = described_class.submit_vote(participant, 1)
      expect(result).to be true
    end
  end

  describe '.voting_complete?' do
    before do
      participant # ensure participant exists
    end

    it 'returns boolean' do
      result = described_class.voting_complete?(instance)
      expect([true, false]).to include(result)
    end
  end

  describe '.available_choices' do
    it 'returns array of choice hashes' do
      choices = described_class.available_choices(branch_round)
      expect(choices).to be_an(Array)
      choices.each do |choice|
        expect(choice).to have_key(:id)
        expect(choice).to have_key(:text)
      end
    end

    it 'uses 1-based option ids for voting' do
      choices = described_class.available_choices(branch_round)
      expect(choices.map { |c| c[:id] }).to eq((1..choices.length).to_a)
    end
  end
end
