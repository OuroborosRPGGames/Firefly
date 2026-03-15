# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityReflexService do
  describe 'ReflexError' do
    it 'is a StandardError' do
      expect(described_class::ReflexError.superclass).to eq(StandardError)
    end
  end

  describe 'ReflexResult struct' do
    it 'has success attribute' do
      result = described_class::ReflexResult.new(success: true)
      expect(result.success).to be true
    end

    it 'has participant_results attribute' do
      result = described_class::ReflexResult.new(participant_results: [])
      expect(result.participant_results).to eq([])
    end

    it 'has emit_text attribute' do
      result = described_class::ReflexResult.new(emit_text: 'Watch out!')
      expect(result.emit_text).to eq('Watch out!')
    end

    it 'has result_text attribute' do
      result = described_class::ReflexResult.new(result_text: 'You dodged!')
      expect(result.result_text).to eq('You dodged!')
    end
  end

  describe 'ParticipantResult struct' do
    it 'has all required attributes' do
      result = described_class::ParticipantResult.new(
        participant_id: 1,
        character_name: 'Test',
        roll_total: 15,
        dc: 12,
        success: true,
        damage_taken: 0
      )

      expect(result.participant_id).to eq(1)
      expect(result.character_name).to eq('Test')
      expect(result.roll_total).to eq(15)
      expect(result.dc).to eq(12)
      expect(result.success).to be true
      expect(result.damage_taken).to eq(0)
    end
  end

  describe '.resolve' do
    let(:instance) { double('ActivityInstance') }
    let(:round) { double('ActivityRound') }
    let(:character_instance) { double('CharacterInstance') }
    let(:character) { double('Character', full_name: 'Test Character') }

    let(:participant) do
      double('ActivityParticipant',
        id: 1,
        character: character,
        character_instance: character_instance,
        instance_id: 100
      )
    end

    let(:active_participants) { double('Dataset') }

    # Helper to build a mock RollResult with the given dice values
    def mock_roll_result(dice_values)
      double('RollResult', dice: dice_values, explosions: [], total: dice_values.sum)
    end

    before do
      allow(round).to receive(:reflex?).and_return(true)
      allow(round).to receive(:difficulty_class).and_return(12)
      allow(round).to receive(:reflex_stat_id).and_return(1)
      allow(round).to receive(:emit_text).and_return('Danger!')
      allow(round).to receive(:success_text).and_return('You reacted!')
      allow(round).to receive(:failure_text).and_return('Too slow!')
      allow(round).to receive(:fail_consequence_type).and_return(nil)

      allow(instance).to receive(:active_participants).and_return(active_participants)
      allow(instance).to receive(:current_difficulty).and_return(12)
      allow(instance).to receive(:difficulty_modifier).and_return(0)

      allow(active_participants).to receive(:empty?).and_return(false)
      allow(active_participants).to receive(:all).and_return([participant])
      allow(active_participants).to receive(:count).and_return(1)

      allow(character_instance).to receive(:take_damage)

      allow(participant).to receive(:update)
      allow(participant).to receive(:willpower_to_spend).and_return(0)
      allow(participant).to receive(:available_willpower).and_return(0)

      # Stub ObserverEffectService to return no effects
      allow(ObserverEffectService).to receive(:effects_for).and_return({})

      # Stub stat_bonus: uses Stat[] + StatAllocationService
      stat_double = double('Stat', abbreviation: 'AGI')
      allow(Stat).to receive(:[]).with(1).and_return(stat_double)
      allow(StatAllocationService).to receive(:get_stat_value).with(character_instance, 'AGI').and_return(2)

      # Stub ActivityResolutionService.roll_base_dice to return predictable results
      # Default: dice [5, 5] → sum 10, + stat_bonus 2 = 12 >= DC 12
      allow(ActivityResolutionService).to receive(:roll_base_dice)
        .and_return(mock_roll_result([5, 5]))
    end

    context 'with invalid round' do
      before do
        allow(round).to receive(:reflex?).and_return(false)
      end

      it 'raises ReflexError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::ReflexError, 'Not a reflex round')
      end
    end

    context 'with no active participants' do
      before do
        allow(active_participants).to receive(:empty?).and_return(true)
      end

      it 'raises ReflexError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::ReflexError, 'No active participants')
      end
    end

    context 'when participant succeeds' do
      before do
        # dice [5, 5] + stat bonus 2 = 12 >= 12 (DC)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([5, 5]))
      end

      it 'returns successful result' do
        result = described_class.resolve(instance, round)

        expect(result.success).to be true
        expect(result.participant_results.first.success).to be true
      end

      it 'does not take damage' do
        expect(character_instance).not_to receive(:take_damage)

        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.damage_taken).to eq(0)
      end

      it 'updates participant roll result' do
        expect(participant).to receive(:update).with(
          roll_result: 12,  # 5 + 5 + 2
          expect_roll: 12
        )

        described_class.resolve(instance, round)
      end

      it 'returns success text' do
        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('You reacted!')
      end
    end

    context 'when participant fails' do
      before do
        # dice [2, 2] + stat bonus 2 = 6 < 12 (DC)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([2, 2]))
      end

      it 'returns failed result' do
        result = described_class.resolve(instance, round)

        expect(result.success).to be false
        expect(result.participant_results.first.success).to be false
      end

      it 'takes 1 damage' do
        expect(character_instance).to receive(:take_damage).with(1)

        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.damage_taken).to eq(1)
      end

      it 'returns failure text' do
        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('Too slow!')
      end
    end

    context 'with default text' do
      before do
        allow(round).to receive(:success_text).and_return(nil)
        allow(round).to receive(:failure_text).and_return(nil)
        # Successful roll: dice [5, 5] + 2 = 12 >= 12
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([5, 5]))
      end

      it 'uses default success text' do
        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('You react in time!')
      end

      it 'uses default failure text when failing' do
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([2, 2]))

        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('Too slow!')
      end
    end

    context 'with explicit round difficulty' do
      before do
        allow(instance).to receive(:difficulty_modifier).and_return(3)
        # Round difficulty is explicit (12), so instance modifier is not reapplied.
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([5, 5]))
      end

      it 'uses the round DC without double-applying instance modifier' do
        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.dc).to eq(12)
        expect(result.participant_results.first.success).to be true
      end
    end

    context 'with multiple participants' do
      let(:participant2) do
        double('ActivityParticipant',
          id: 2,
          character: double('Character', full_name: 'Second Character'),
          character_instance: character_instance,
          instance_id: 100
        )
      end

      before do
        allow(active_participants).to receive(:all).and_return([participant, participant2])
        allow(active_participants).to receive(:count).and_return(2)
        allow(participant2).to receive(:update)
        allow(participant2).to receive(:willpower_to_spend).and_return(0)
        allow(participant2).to receive(:available_willpower).and_return(0)
      end

      context 'when majority succeeds' do
        before do
          # Both roll [5, 5] + 2 = 12 >= DC 12
          allow(ActivityResolutionService).to receive(:roll_base_dice)
            .and_return(mock_roll_result([5, 5]))
        end

        it 'returns overall success' do
          result = described_class.resolve(instance, round)

          expect(result.success).to be true
        end
      end

      context 'when majority fails' do
        before do
          # Both roll [2, 2] + 2 = 6 < DC 12
          allow(ActivityResolutionService).to receive(:roll_base_dice)
            .and_return(mock_roll_result([2, 2]))
        end

        it 'returns overall failure' do
          result = described_class.resolve(instance, round)

          expect(result.success).to be false
        end
      end
    end

    context 'with failure consequences' do
      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([2, 2]))  # Fail
      end

      context 'with difficulty consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('difficulty')
          allow(instance).to receive(:add_difficulty_modifier!)
        end

        it 'adds difficulty modifier' do
          expect(instance).to receive(:add_difficulty_modifier!).with(1)

          described_class.resolve(instance, round)
        end
      end

      context 'with harder_finale consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('harder_finale')
          allow(instance).to receive(:add_finale_modifier!)
        end

        it 'adds finale modifier' do
          expect(instance).to receive(:add_finale_modifier!).with(1)

          described_class.resolve(instance, round)
        end
      end
    end

    context 'when character has no stat' do
      before do
        # Stat lookup returns nil → stat_bonus returns 0
        allow(Stat).to receive(:[]).with(1).and_return(nil)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([6, 6]))
      end

      it 'uses 0 for stat bonus' do
        result = described_class.resolve(instance, round)

        # 6 + 6 + 0 = 12 >= 12
        expect(result.participant_results.first.roll_total).to eq(12)
      end
    end

    context 'when character_instance is nil' do
      before do
        allow(participant).to receive(:character_instance).and_return(nil)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([2, 2]))  # Fail
      end

      it 'does not try to take damage' do
        # Should not raise error
        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.damage_taken).to eq(0)
      end
    end

    context 'with nil round difficulty' do
      before do
        allow(round).to receive(:difficulty_class).and_return(nil)
        allow(instance).to receive(:current_difficulty).and_return(15)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([5, 5]))
      end

      it 'uses instance current_difficulty' do
        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.dc).to eq(15)
      end
    end

    context 'with nil character' do
      before do
        allow(participant).to receive(:character).and_return(nil)
        allow(ActivityResolutionService).to receive(:roll_base_dice)
          .and_return(mock_roll_result([5, 5]))
      end

      it 'uses Unknown for character name' do
        result = described_class.resolve(instance, round)

        expect(result.participant_results.first.character_name).to eq('Unknown')
      end
    end
  end

  describe 'private methods' do
    describe '#stat_bonus' do
      let(:character_instance) { double('CharacterInstance') }

      it 'returns 0 for nil character_instance' do
        result = described_class.send(:stat_bonus, nil, 1)

        expect(result).to eq(0)
      end

      it 'returns 0 for nil stat_id' do
        result = described_class.send(:stat_bonus, character_instance, nil)

        expect(result).to eq(0)
      end

      it 'returns stat value when available' do
        stat_double = double('Stat', abbreviation: 'STR')
        allow(Stat).to receive(:[]).with(1).and_return(stat_double)
        allow(StatAllocationService).to receive(:get_stat_value)
          .with(character_instance, 'STR').and_return(3)

        result = described_class.send(:stat_bonus, character_instance, 1)

        expect(result).to eq(3)
      end

      it 'returns 0 when stat is not found' do
        allow(Stat).to receive(:[]).with(1).and_return(nil)

        result = described_class.send(:stat_bonus, character_instance, 1)

        expect(result).to eq(0)
      end

      it 'returns 0 when stat value returns nil' do
        stat_double = double('Stat', abbreviation: 'STR')
        allow(Stat).to receive(:[]).with(1).and_return(stat_double)
        allow(StatAllocationService).to receive(:get_stat_value)
          .with(character_instance, 'STR').and_return(nil)

        result = described_class.send(:stat_bonus, character_instance, 1)

        expect(result).to eq(0)
      end
    end
  end
end
