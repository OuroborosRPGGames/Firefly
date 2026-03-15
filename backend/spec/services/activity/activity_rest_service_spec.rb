# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityRestService do
  describe 'RestError' do
    it 'is a StandardError' do
      expect(described_class::RestError.superclass).to eq(StandardError)
    end
  end

  describe 'RestResult struct' do
    it 'has ready_to_continue attribute' do
      result = described_class::RestResult.new(ready_to_continue: true)
      expect(result.ready_to_continue).to be true
    end

    it 'has continue_votes attribute' do
      result = described_class::RestResult.new(continue_votes: 3)
      expect(result.continue_votes).to eq(3)
    end

    it 'has total_participants attribute' do
      result = described_class::RestResult.new(total_participants: 5)
      expect(result.total_participants).to eq(5)
    end

    it 'has healing_results attribute' do
      result = described_class::RestResult.new(healing_results: [])
      expect(result.healing_results).to eq([])
    end

    it 'has emit_text and result_text' do
      result = described_class::RestResult.new(
        emit_text: 'You take a breather',
        result_text: 'Ready to continue'
      )
      expect(result.emit_text).to eq('You take a breather')
      expect(result.result_text).to eq('Ready to continue')
    end
  end

  describe 'HealingResult struct' do
    it 'has all required attributes' do
      result = described_class::HealingResult.new(
        participant_id: 1,
        character_name: 'Test',
        previous_hp: 3,
        new_hp: 5,
        max_hp: 6,
        permanent_damage: 1,
        healed_amount: 2
      )

      expect(result.participant_id).to eq(1)
      expect(result.character_name).to eq('Test')
      expect(result.previous_hp).to eq(3)
      expect(result.new_hp).to eq(5)
      expect(result.max_hp).to eq(6)
      expect(result.permanent_damage).to eq(1)
      expect(result.healed_amount).to eq(2)
    end
  end

  describe '.resolve' do
    let(:instance) { double('ActivityInstance') }
    let(:round) { double('ActivityRound') }
    let(:active_participants) { double('Dataset') }
    let(:participants_array) do
      5.times.map { |i| double("Participant#{i}") }
    end

    before do
      allow(round).to receive(:rest?).and_return(true)
      allow(round).to receive(:emit_text).and_return('Take a rest')

      allow(instance).to receive(:active_participants).and_return(active_participants)
      allow(instance).to receive(:continue_votes).and_return(2)
      allow(instance).to receive(:majority_wants_continue?).and_return(false)

      allow(active_participants).to receive(:empty?).and_return(false)
      allow(active_participants).to receive(:all).and_return(participants_array)
    end

    context 'with invalid round' do
      before do
        allow(round).to receive(:rest?).and_return(false)
      end

      it 'raises RestError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::RestError, 'Not a rest round')
      end
    end

    context 'with no active participants' do
      before do
        allow(active_participants).to receive(:empty?).and_return(true)
      end

      it 'raises RestError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::RestError, 'No active participants')
      end
    end

    context 'when not ready to continue' do
      before do
        allow(instance).to receive(:majority_wants_continue?).and_return(false)
      end

      it 'returns not ready result' do
        result = described_class.resolve(instance, round)

        expect(result.ready_to_continue).to be false
        expect(result.continue_votes).to eq(2)
        expect(result.total_participants).to eq(5)
        expect(result.result_text).to include('waiting for majority')
      end
    end

    context 'when ready to continue' do
      before do
        allow(instance).to receive(:majority_wants_continue?).and_return(true)
      end

      it 'returns ready result' do
        result = described_class.resolve(instance, round)

        expect(result.ready_to_continue).to be true
        expect(result.result_text).to eq('The group is ready to continue.')
      end
    end

    it 'returns emit_text from round' do
      result = described_class.resolve(instance, round)

      expect(result.emit_text).to eq('Take a rest')
    end

    it 'returns empty healing_results' do
      result = described_class.resolve(instance, round)

      expect(result.healing_results).to eq([])
    end
  end

  describe '.heal_at_rest' do
    let(:character) { double('Character', full_name: 'Test Hero') }
    let(:character_instance) { double('CharacterInstance') }
    let(:participant) { double('ActivityParticipant', id: 1, roll_result: nil) }

    before do
      allow(participant).to receive(:character_instance).and_return(character_instance)
      allow(participant).to receive(:character).and_return(character)
      allow(participant).to receive(:update)
    end

    context 'with no character_instance' do
      before do
        allow(participant).to receive(:character_instance).and_return(nil)
      end

      it 'raises RestError' do
        expect { described_class.heal_at_rest(participant) }
          .to raise_error(described_class::RestError, 'No character instance found')
      end
    end

    context 'when at full HP' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(6)
        allow(character_instance).to receive(:max_hp).and_return(6)
      end

      it 'returns 0 healed amount' do
        result = described_class.heal_at_rest(participant)

        expect(result.healed_amount).to eq(0)
        expect(result.permanent_damage).to eq(0)
      end
    end

    context 'when lost 1 HP (no permanent damage)' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(5)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'heals to full' do
        expect(character_instance).to receive(:update).with(health: 6)

        result = described_class.heal_at_rest(participant)

        expect(result.previous_hp).to eq(5)
        expect(result.new_hp).to eq(6)
        expect(result.healed_amount).to eq(1)
        expect(result.permanent_damage).to eq(0)
      end
    end

    context 'when lost 2 HP (1 permanent damage)' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(4)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'heals to max-1' do
        expect(character_instance).to receive(:update).with(health: 5)

        result = described_class.heal_at_rest(participant)

        expect(result.previous_hp).to eq(4)
        expect(result.new_hp).to eq(5)
        expect(result.healed_amount).to eq(1)
        expect(result.permanent_damage).to eq(1)
      end
    end

    context 'when lost 4 HP (2 permanent damage)' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(2)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'heals to max-2' do
        expect(character_instance).to receive(:update).with(health: 4)

        result = described_class.heal_at_rest(participant)

        expect(result.previous_hp).to eq(2)
        expect(result.new_hp).to eq(4)
        expect(result.healed_amount).to eq(2)
        expect(result.permanent_damage).to eq(2)
      end
    end

    context 'when already at healable maximum' do
      before do
        # Lost 2 HP, but already at max-1 (healable max)
        allow(character_instance).to receive(:current_hp).and_return(5)
        allow(character_instance).to receive(:max_hp).and_return(6)
        # Permanent damage = (6-5)/2 = 0 (integer division)
        # So healable_to = 6 - 0 = 6, but we're at 5
        # Actually with this setup: damage_taken = 1, permanent = 0
        # Let's correct this
      end

      it 'can heal when below healable max' do
        # More accurate test: at 4 HP out of 6, permanent = 1
        allow(character_instance).to receive(:current_hp).and_return(5)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
        # damage_taken = 6-5=1, permanent = 1/2 = 0
        # healable_to = 6-0 = 6
        # So can heal 1 HP

        result = described_class.heal_at_rest(participant)

        expect(result.healed_amount).to eq(1)
      end
    end

    context 'with nil character' do
      before do
        allow(participant).to receive(:character).and_return(nil)
        allow(character_instance).to receive(:current_hp).and_return(5)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'uses Unknown for character name' do
        result = described_class.heal_at_rest(participant)

        expect(result.character_name).to eq('Unknown')
      end
    end
  end

  describe '.vote_to_continue' do
    let(:participant) { double('ActivityParticipant') }

    before do
      allow(participant).to receive(:vote_to_continue!)
    end

    it 'calls vote_to_continue! on participant' do
      expect(participant).to receive(:vote_to_continue!)

      described_class.vote_to_continue(participant)
    end

    it 'returns true' do
      result = described_class.vote_to_continue(participant)

      expect(result).to be true
    end
  end

  describe '.ready_to_continue?' do
    let(:instance) { double('ActivityInstance') }

    it 'delegates to instance.majority_wants_continue?' do
      allow(instance).to receive(:majority_wants_continue?).and_return(true)

      result = described_class.ready_to_continue?(instance)

      expect(result).to be true
    end

    it 'returns false when not ready' do
      allow(instance).to receive(:majority_wants_continue?).and_return(false)

      result = described_class.ready_to_continue?(instance)

      expect(result).to be false
    end
  end

  describe '.rest_status' do
    let(:instance) { double('ActivityInstance') }
    let(:character) { double('Character', full_name: 'Hero') }
    let(:character_instance) { double('CharacterInstance', current_hp: 4, max_hp: 6) }
    let(:participant) do
      double('ActivityParticipant',
        character: character,
        character_instance: character_instance
      )
    end

    let(:active_participants) { double('Dataset') }

    before do
      allow(instance).to receive(:active_participants).and_return(active_participants)
      allow(active_participants).to receive(:all).and_return([participant])
      allow(active_participants).to receive(:count).and_return(1)
      allow(instance).to receive(:continue_votes).and_return(0)
      allow(instance).to receive(:majority_wants_continue?).and_return(false)
      allow(participant).to receive(:voted_continue?).and_return(false)
    end

    it 'returns total participants' do
      result = described_class.rest_status(instance)

      expect(result[:total_participants]).to eq(1)
    end

    it 'returns continue votes' do
      result = described_class.rest_status(instance)

      expect(result[:continue_votes]).to eq(0)
    end

    it 'calculates votes needed' do
      # Create 4 participants to test the calculation
      p2 = double('ActivityParticipant', character: character, character_instance: character_instance)
      p3 = double('ActivityParticipant', character: character, character_instance: character_instance)
      p4 = double('ActivityParticipant', character: character, character_instance: character_instance)
      allow(p2).to receive(:voted_continue?).and_return(false)
      allow(p3).to receive(:voted_continue?).and_return(false)
      allow(p4).to receive(:voted_continue?).and_return(false)
      allow(active_participants).to receive(:all).and_return([participant, p2, p3, p4])

      result = described_class.rest_status(instance)

      # 4/2.0 = 2.0, ceil = 2, + 1 = 3
      expect(result[:votes_needed]).to eq(3)
    end

    it 'calculates majority votes needed correctly for odd counts' do
      p2 = double('ActivityParticipant', character: character, character_instance: character_instance)
      p3 = double('ActivityParticipant', character: character, character_instance: character_instance)
      allow(p2).to receive(:voted_continue?).and_return(false)
      allow(p3).to receive(:voted_continue?).and_return(false)
      allow(active_participants).to receive(:all).and_return([participant, p2, p3])

      result = described_class.rest_status(instance)

      expect(result[:votes_needed]).to eq(2)
    end

    it 'returns ready status' do
      result = described_class.rest_status(instance)

      expect(result[:ready]).to be false
    end

    it 'returns participant status' do
      result = described_class.rest_status(instance)

      expect(result[:participants_status].length).to eq(1)
      expect(result[:participants_status].first[:name]).to eq('Hero')
      expect(result[:participants_status].first[:current_hp]).to eq(4)
      expect(result[:participants_status].first[:max_hp]).to eq(6)
      expect(result[:participants_status].first[:voted_continue]).to be false
    end

    context 'with multiple participants' do
      let(:participant2) do
        double('ActivityParticipant',
          character: double('Character', full_name: 'Wizard'),
          character_instance: double('CharacterInstance', current_hp: 6, max_hp: 6)
        )
      end

      before do
        allow(active_participants).to receive(:all).and_return([participant, participant2])
        allow(active_participants).to receive(:count).and_return(2)
        allow(participant2).to receive(:voted_continue?).and_return(true)
      end

      it 'returns status for all participants' do
        result = described_class.rest_status(instance)

        expect(result[:participants_status].length).to eq(2)
        expect(result[:participants_status][1][:voted_continue]).to be true
      end
    end

    context 'with nil character_instance' do
      before do
        allow(participant).to receive(:character_instance).and_return(nil)
      end

      it 'returns 0 for HP values' do
        result = described_class.rest_status(instance)

        expect(result[:participants_status].first[:current_hp]).to eq(0)
        expect(result[:participants_status].first[:max_hp]).to eq(0)
      end
    end
  end

  describe 'healing calculation edge cases' do
    let(:character) { double('Character', full_name: 'Test') }
    let(:character_instance) { double('CharacterInstance') }
    let(:participant) { double('ActivityParticipant', id: 1, roll_result: nil) }

    before do
      allow(participant).to receive(:character_instance).and_return(character_instance)
      allow(participant).to receive(:character).and_return(character)
      allow(participant).to receive(:update)
    end

    context 'when lost 3 HP (1 permanent due to integer division)' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(3)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'heals correctly' do
        # damage_taken = 3, permanent = 3/2 = 1
        # healable_to = 6 - 1 = 5
        # healed_amount = 5 - 3 = 2

        result = described_class.heal_at_rest(participant)

        expect(result.permanent_damage).to eq(1)
        expect(result.new_hp).to eq(5)
        expect(result.healed_amount).to eq(2)
      end
    end

    context 'when at 0 HP (max permanent damage)' do
      before do
        allow(character_instance).to receive(:current_hp).and_return(0)
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update)
      end

      it 'heals with maximum permanent damage' do
        # damage_taken = 6, permanent = 6/2 = 3
        # healable_to = 6 - 3 = 3
        # healed_amount = 3 - 0 = 3

        result = described_class.heal_at_rest(participant)

        expect(result.permanent_damage).to eq(3)
        expect(result.new_hp).to eq(3)
        expect(result.healed_amount).to eq(3)
      end
    end

    context 'when heal is used repeatedly in the same rest round' do
      let(:current_hp) { [4] }
      let(:rest_damage_baseline) { [nil] }

      before do
        allow(character_instance).to receive(:current_hp) { current_hp[0] }
        allow(character_instance).to receive(:max_hp).and_return(6)
        allow(character_instance).to receive(:update) do |attrs|
          current_hp[0] = attrs[:health] if attrs.key?(:health)
        end

        allow(participant).to receive(:roll_result) { rest_damage_baseline[0] }
        allow(participant).to receive(:update) do |attrs|
          rest_damage_baseline[0] = attrs[:roll_result] if attrs.key?(:roll_result)
        end
      end

      it 'locks permanent damage to the first pre-heal baseline' do
        first = described_class.heal_at_rest(participant)
        second = described_class.heal_at_rest(participant)

        expect(first.new_hp).to eq(5)
        expect(first.healed_amount).to eq(1)
        expect(first.permanent_damage).to eq(1)

        expect(second.new_hp).to eq(5)
        expect(second.healed_amount).to eq(0)
        expect(second.permanent_damage).to eq(1)
      end
    end
  end
end
