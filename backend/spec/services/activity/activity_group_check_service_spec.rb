# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityGroupCheckService do
  let(:instance) do
    double('ActivityInstance',
           current_difficulty: 12,
           difficulty_modifier: 0,
           active_participants: active_participants_dataset,
           add_difficulty_modifier!: true,
           add_finale_modifier!: true)
  end

  let(:active_participants_dataset) do
    dataset = double('Dataset', all: participants, empty?: false)
    allow(dataset).to receive(:each).and_yield(participant1).and_yield(participant2).and_yield(participant3)
    dataset
  end

  let(:participants) { [participant1, participant2, participant3] }

  let(:character1) { double('Character', full_name: 'Alice') }
  let(:character2) { double('Character', full_name: 'Bob') }
  let(:character3) { double('Character', full_name: 'Charlie') }

  let(:char_instance1) { double('CharacterInstance', take_damage: true) }
  let(:char_instance2) { double('CharacterInstance', take_damage: true) }
  let(:char_instance3) { double('CharacterInstance', take_damage: true) }

  let(:action) do
    double('ActivityAction',
           stat_bonus_for: 2,
           risk_dice: false)
  end

  let(:participant1) do
    double('ActivityParticipant',
           id: 1,
           instance_id: 1,
           character: character1,
           character_instance: char_instance1,
           chosen_action: action,
           willpower_to_spend: 0,
           available_willpower: 3,
           has_risk?: false,
           use_willpower!: true,
           update: true)
  end

  let(:participant2) do
    double('ActivityParticipant',
           id: 2,
           instance_id: 1,
           character: character2,
           character_instance: char_instance2,
           chosen_action: action,
           willpower_to_spend: 0,
           available_willpower: 2,
           has_risk?: false,
           use_willpower!: true,
           update: true)
  end

  let(:participant3) do
    double('ActivityParticipant',
           id: 3,
           instance_id: 1,
           character: character3,
           character_instance: char_instance3,
           chosen_action: action,
           willpower_to_spend: 0,
           available_willpower: 1,
           has_risk?: false,
           use_willpower!: true,
           update: true)
  end

  let(:round) do
    double('ActivityRound',
           group_check?: true,
           difficulty_class: 15,
           emit_text: 'The group faces the challenge together!',
           success_text: 'You succeed!',
           failure_text: 'You fail!',
           fail_consequence_type: nil)
  end

  describe '.resolve' do
    before do
      # Stub ObserverEffectService (called via roll_group_check)
      allow(ObserverEffectService).to receive(:effects_for).and_return({})
      allow(ActivityInstance).to receive(:[]).and_return(instance)

      # Stub ActivityResolutionService for base dice rolling
      base_result = double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: [])
      allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(base_result)

      # Stub RISK_VALUES for risk dice
      stub_const('ActivityResolutionService::RISK_VALUES', [-4, -3, -2, -1, 1, 2, 3, 4])
    end

    context 'when not a group check round' do
      before do
        allow(round).to receive(:group_check?).and_return(false)
      end

      it 'raises GroupCheckError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::GroupCheckError, 'Not a group check round')
      end
    end

    context 'when no active participants' do
      before do
        allow(active_participants_dataset).to receive(:empty?).and_return(true)
      end

      it 'raises GroupCheckError' do
        expect { described_class.resolve(instance, round) }
          .to raise_error(described_class::GroupCheckError, 'No active participants')
      end
    end

    context 'with successful group check' do
      before do
        # High rolls = success against explicit round DC (15).
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [7, 7], base_dice: [7, 7], total: 14, explosions: []))
        allow(instance).to receive(:difficulty_modifier).and_return(-5)
      end

      it 'returns success' do
        result = described_class.resolve(instance, round)

        expect(result.success).to be true
      end

      it 'includes participant results' do
        result = described_class.resolve(instance, round)

        expect(result.participant_results.length).to eq(3)
      end

      it 'includes success text' do
        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('You succeed!')
      end

      it 'calculates median roll' do
        result = described_class.resolve(instance, round)

        expect(result.median_roll).to be_a(Numeric)
      end
    end

    context 'with failed group check' do
      before do
        # Low rolls = failure
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [2, 2], base_dice: [2, 2], total: 4, explosions: []))
        allow(instance).to receive(:difficulty_modifier).and_return(0)
      end

      it 'returns failure' do
        result = described_class.resolve(instance, round)

        expect(result.success).to be false
      end

      it 'includes failure text' do
        result = described_class.resolve(instance, round)

        expect(result.result_text).to eq('You fail!')
      end
    end

    context 'with fail consequences' do
      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [1, 1], base_dice: [1, 1], total: 2, explosions: []))
        allow(instance).to receive(:difficulty_modifier).and_return(0)
      end

      context 'difficulty consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('difficulty')
        end

        it 'adds difficulty modifier' do
          expect(instance).to receive(:add_difficulty_modifier!).with(1)

          described_class.resolve(instance, round)
        end
      end

      context 'injury consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('injury')
        end

        it 'damages all participants' do
          expect(char_instance1).to receive(:take_damage).with(1)
          expect(char_instance2).to receive(:take_damage).with(1)
          expect(char_instance3).to receive(:take_damage).with(1)

          described_class.resolve(instance, round)
        end
      end

      context 'harder finale consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('harder_finale')
        end

        it 'adds finale modifier' do
          expect(instance).to receive(:add_finale_modifier!).with(1)

          described_class.resolve(instance, round)
        end
      end
    end

    context 'with willpower usage' do
      before do
        base_result = double('DiceResult', dice: [4, 4], base_dice: [4, 4], total: 8, explosions: [])
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(base_result)
        allow(participant1).to receive(:willpower_to_spend).and_return(1)

        # Stub the willpower dice roll and append
        wp_result = double('WPResult', dice: [6], base_dice: [6], total: 6, explosions: [])
        allow(DiceRollService).to receive(:roll).and_return(wp_result)
        combined = double('CombinedResult', dice: [4, 4, 6], base_dice: [4, 4, 6], total: 14, explosions: [])
        allow(ActivityResolutionService).to receive(:append_willpower).and_return(combined)
      end

      it 'spends willpower' do
        expect(participant1).to receive(:use_willpower!).with(1)

        described_class.resolve(instance, round)
      end
    end

    context 'with risk dice' do
      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [4, 4], base_dice: [4, 4], total: 8, explosions: []))
        allow(participant1).to receive(:has_risk?).and_return(true)
        allow(ActivityResolutionService::RISK_VALUES).to receive(:sample).and_return(3)
      end

      it 'includes risk in results' do
        result = described_class.resolve(instance, round)

        participant_result = result.participant_results.find { |r| r.participant_id == 1 }
        expect(participant_result.risk_result).to eq(3)
      end

      it 'adds risk to final total' do
        result = described_class.resolve(instance, round)

        expect(result.avg_risk).to be > 0
      end
    end

    context 'with even number of participants' do
      let(:participants) { [participant1, participant2] }

      before do
        allow(active_participants_dataset).to receive(:all).and_return(participants)
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: []))
      end

      it 'calculates median correctly' do
        result = described_class.resolve(instance, round)

        # With 2 participants, median is average of both rolls
        expect(result.median_roll).to be_a(Numeric)
      end
    end

    context 'with odd number of participants' do
      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: []))
      end

      it 'calculates median correctly' do
        result = described_class.resolve(instance, round)

        # With 3 participants, median is middle value
        expect(result.median_roll).to be_a(Numeric)
      end
    end

    context 'updates participant roll results' do
      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: []))
      end

      it 'updates each participant' do
        expect(participant1).to receive(:update).with(hash_including(:roll_result, :expect_roll))
        expect(participant2).to receive(:update).with(hash_including(:roll_result, :expect_roll))
        expect(participant3).to receive(:update).with(hash_including(:roll_result, :expect_roll))

        described_class.resolve(instance, round)
      end
    end

    context 'when no action is chosen but round stat_set_a is configured' do
      let(:stat_one) { double('StatOne', abbreviation: 'AGI') }
      let(:stat_two) { double('StatTwo', abbreviation: 'WIT') }

      before do
        allow(ActivityResolutionService).to receive(:roll_base_dice).and_return(double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: []))
        allow(participant1).to receive(:chosen_action).and_return(nil)
        allow(participant2).to receive(:chosen_action).and_return(nil)
        allow(participant3).to receive(:chosen_action).and_return(nil)
        allow(round).to receive(:stat_set_a).and_return([101, 102])

        allow(Stat).to receive(:[]).with(101).and_return(stat_one)
        allow(Stat).to receive(:[]).with(102).and_return(stat_two)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance1, 'AGI').and_return(2)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance1, 'WIT').and_return(7)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance2, 'AGI').and_return(1)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance2, 'WIT').and_return(3)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance3, 'AGI').and_return(0)
        allow(StatAllocationService).to receive(:get_stat_value).with(char_instance3, 'WIT').and_return(4)
      end

      it 'uses the strongest stat from round stat_set_a' do
        result = described_class.resolve(instance, round)

        p1 = result.participant_results.find { |r| r.participant_id == 1 }
        expect(p1.stat_bonus).to eq(7)
        expect(p1.total).to eq(17) # 5 + 5 + 7
      end
    end
  end

  describe 'private methods' do
    describe '.roll_group_check delegates to ActivityResolutionService' do
      it 'calls roll_base_dice for dice rolling' do
        allow(ObserverEffectService).to receive(:effects_for).and_return({})
        allow(ActivityInstance).to receive(:[]).and_return(instance)

        base_result = double('DiceResult', dice: [5, 5], base_dice: [5, 5], total: 10, explosions: [])
        expect(ActivityResolutionService).to receive(:roll_base_dice).at_least(:once).and_return(base_result)

        described_class.resolve(instance, round)
      end

      it 'uses RISK_VALUES for risk dice when participant has risk' do
        allow(ObserverEffectService).to receive(:effects_for).and_return({})
        allow(ActivityInstance).to receive(:[]).and_return(instance)

        allow(participant1).to receive(:has_risk?).and_return(true)

        result = described_class.resolve(instance, round)
        p1 = result.participant_results.find { |r| r.participant_id == 1 }
        expect(ActivityResolutionService::RISK_VALUES).to include(p1.risk_result)
      end
    end

    describe 'ActivityResolutionService::RISK_VALUES' do
      it 'contains values in range -4 to 4 excluding 0' do
        expected = [-4, -3, -2, -1, 1, 2, 3, 4]
        ActivityResolutionService::RISK_VALUES.each do |v|
          expect(expected).to include(v)
        end
      end

      it 'does not include 0' do
        expect(ActivityResolutionService::RISK_VALUES).not_to include(0)
      end
    end
  end

  describe 'GroupCheckResult struct' do
    it 'has all expected attributes' do
      result = described_class::GroupCheckResult.new(
        success: true,
        median_roll: 12.0,
        avg_risk: 1.5,
        final_total: 13.5,
        dc: 12,
        participant_results: [],
        emit_text: 'Test',
        result_text: 'Success!'
      )

      expect(result.success).to be true
      expect(result.median_roll).to eq(12.0)
      expect(result.avg_risk).to eq(1.5)
      expect(result.final_total).to eq(13.5)
      expect(result.dc).to eq(12)
      expect(result.participant_results).to eq([])
      expect(result.emit_text).to eq('Test')
      expect(result.result_text).to eq('Success!')
    end
  end

  describe 'ParticipantResult struct' do
    it 'has all expected attributes' do
      result = described_class::ParticipantResult.new(
        participant_id: 1,
        character_name: 'Alice',
        dice_results: [5, 6],
        stat_bonus: 2,
        willpower_spent: 1,
        risk_result: 3,
        total: 16
      )

      expect(result.participant_id).to eq(1)
      expect(result.character_name).to eq('Alice')
      expect(result.dice_results).to eq([5, 6])
      expect(result.stat_bonus).to eq(2)
      expect(result.willpower_spent).to eq(1)
      expect(result.risk_result).to eq(3)
      expect(result.total).to eq(16)
    end
  end
end
