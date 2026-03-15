# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveSkillCheckService do
  let(:character_instance) do
    instance_double('CharacterInstance')
  end
  let(:delve) do
    instance_double('Delve',
                    active_participants: [])
  end
  let(:participant) do
    instance_double('DelveParticipant',
                    id: 1,
                    character_instance: character_instance,
                    current_level: 1,
                    delve: delve,
                    spend_time_seconds!: :ok,
                    take_hp_damage!: true,
                    mark_blocker_cleared!: true,
                    has_cleared_blocker?: false,
                    active?: true)
  end
  let(:blocker) do
    instance_double('DelveBlocker',
                    id: 1,
                    blocker_type: 'barricade',
                    stat_for_check: 'STR',
                    easier_attempts: 0,
                    effective_difficulty: 12,
                    causes_damage_on_fail?: false,
                    clear!: true,
                    increment_easier_attempts!: true)
  end

  describe 'class methods' do
    it 'responds to attempt!' do
      expect(described_class).to respond_to(:attempt!)
    end

    it 'responds to make_easier!' do
      expect(described_class).to respond_to(:make_easier!)
    end

    it 'responds to party_bonus' do
      expect(described_class).to respond_to(:party_bonus)
    end
  end

  describe '.attempt!' do
    before do
      allow(StatAllocationService).to receive(:get_stat_value).and_return(14)
      allow(GameSetting).to receive(:integer).with('delve_base_skill_dc').and_return(10)
      allow(GameSetting).to receive(:integer).with('delve_dc_per_level').and_return(2)
      allow(GameSetting).to receive(:integer).with('delve_time_skill_check').and_return(15)
    end

    context 'on success' do
      before do
        allow(DiceRollService).to receive(:roll_2d8_exploding).and_return(
          DiceRollService::RollResult.new(
            dice: [8, 8], base_dice: [8, 8], explosions: [],
            modifier: 2, total: 18, count: 2, sides: 8, explode_on: 8
          )
        )
      end

      it 'clears the blocker' do
        expect(blocker).to receive(:clear!)
        described_class.attempt!(participant, blocker)
      end

      it 'marks blocker cleared on participant' do
        expect(participant).to receive(:mark_blocker_cleared!).with(blocker.id)
        described_class.attempt!(participant, blocker)
      end

      it 'returns success result' do
        result = described_class.attempt!(participant, blocker)
        expect(result.success).to be true
        expect(result.data[:cleared]).to be true
      end

      it 'includes roll information in message' do
        result = described_class.attempt!(participant, blocker)
        expect(result.message).to include('successfully')
        expect(result.message).to include('vs DC')
      end

      it 'formats roll with brackets and vs DC' do
        result = described_class.attempt!(participant, blocker)
        expect(result.message).to match(/\[\d+, \d+\]/)
        expect(result.message).to include('vs DC')
      end

      it 'spends time' do
        expect(participant).to receive(:spend_time_seconds!).with(15)
        described_class.attempt!(participant, blocker)
      end
    end

    context 'on failure with non-damaging blocker' do
      before do
        allow(DiceRollService).to receive(:roll_2d8_exploding).and_return(
          DiceRollService::RollResult.new(
            dice: [1, 1], base_dice: [1, 1], explosions: [],
            modifier: -1, total: 1, count: 2, sides: 8, explode_on: 8
          )
        )
        allow(StatAllocationService).to receive(:get_stat_value).and_return(8) # Low stat
      end

      it 'does not clear the blocker' do
        expect(blocker).not_to receive(:clear!)
        described_class.attempt!(participant, blocker)
      end

      it 'returns success result (narrative, not error)' do
        result = described_class.attempt!(participant, blocker)
        expect(result.success).to be true
        expect(result.data[:cleared]).to be false
      end

      it 'includes fail message with easier hint' do
        result = described_class.attempt!(participant, blocker)
        expect(result.message).to include('fail')
        expect(result.message).to include('easier')
      end

      it 'formats roll with brackets and vs DC' do
        result = described_class.attempt!(participant, blocker)
        expect(result.message).to match(/\[\d+, \d+\]/)
        expect(result.message).to include('vs DC')
      end
    end

    context 'on failure with damaging blocker (gap/narrow)' do
      before do
        allow(blocker).to receive(:causes_damage_on_fail?).and_return(true)
        allow(blocker).to receive(:blocker_type).and_return('gap')
        allow(DiceRollService).to receive(:roll_2d8_exploding).and_return(
          DiceRollService::RollResult.new(
            dice: [1, 1], base_dice: [1, 1], explosions: [],
            modifier: -1, total: 1, count: 2, sides: 8, explode_on: 8
          )
        )
        allow(StatAllocationService).to receive(:get_stat_value).and_return(8)
      end

      it 'deals damage to participant' do
        expect(participant).to receive(:take_hp_damage!).with(1) # current_level
        described_class.attempt!(participant, blocker)
      end

      it 'does not clear the blocker (gap/narrow remain as obstacles)' do
        expect(blocker).not_to receive(:clear!)
        described_class.attempt!(participant, blocker)
      end

      it 'returns success with damage info' do
        result = described_class.attempt!(participant, blocker)
        expect(result.success).to be true
        expect(result.data[:damage]).to eq(1)
        expect(result.data[:cleared]).to be true
      end
    end

    it 'applies party bonus when provided' do
      expect(participant).to receive(:spend_time_seconds!)
      described_class.attempt!(participant, blocker, party_bonus: 4)
    end
  end

  describe '.make_easier!' do
    before do
      allow(GameSetting).to receive(:integer).with('delve_time_easier').and_return(30)
    end

    it 'spends time' do
      expect(participant).to receive(:spend_time_seconds!).with(30)
      described_class.make_easier!(participant, blocker)
    end

    it 'increments easier attempts on blocker' do
      expect(blocker).to receive(:increment_easier_attempts!)
      described_class.make_easier!(participant, blocker)
    end

    it 'returns success result with new difficulty' do
      result = described_class.make_easier!(participant, blocker)
      expect(result.success).to be true
      expect(result.data[:new_dc]).to eq(12)
    end
  end

  describe 'willpower usage' do
    before do
      allow(StatAllocationService).to receive(:get_stat_value).and_return(14)
      allow(GameSetting).to receive(:integer).with('delve_base_skill_dc').and_return(10)
      allow(GameSetting).to receive(:integer).with('delve_dc_per_level').and_return(2)
      allow(GameSetting).to receive(:integer).with('delve_time_skill_check').and_return(15)
      allow(DiceRollService).to receive(:roll_2d8_exploding).and_return(
        DiceRollService::RollResult.new(
          dice: [4, 5], base_dice: [4, 5], explosions: [],
          modifier: 2, total: 11, count: 2, sides: 8, explode_on: 8
        )
      )
    end

    context 'when use_willpower is true and participant has dice' do
      before do
        allow(participant).to receive(:willpower_dice).and_return(2)
        allow(participant).to receive(:use_willpower!).and_return(true)
      end

      it 'spends willpower' do
        expect(participant).to receive(:use_willpower!)
        described_class.attempt!(participant, blocker, use_willpower: true)
      end

      it 'includes WP in roll display' do
        result = described_class.attempt!(participant, blocker, use_willpower: true)
        expect(result.message).to include('WP')
      end
    end

    context 'when use_willpower is false' do
      it 'does not spend willpower' do
        expect(participant).not_to receive(:use_willpower!)
        described_class.attempt!(participant, blocker)
      end
    end

    context 'when use_willpower is true but participant has no dice' do
      before do
        allow(participant).to receive(:use_willpower!).and_return(false)
      end

      it 'does not add extra dice' do
        result = described_class.attempt!(participant, blocker, use_willpower: true)
        expect(result.message).not_to include('WP')
      end
    end
  end

  describe '.party_bonus' do
    let(:other_participant) do
      instance_double('DelveParticipant',
                      id: 2,
                      has_cleared_blocker?: true)
    end

    before do
      allow(delve).to receive(:active_participants).and_return([participant, other_participant])
    end

    it 'returns 0 for non-damaging blockers' do
      allow(blocker).to receive(:causes_damage_on_fail?).and_return(false)
      result = described_class.party_bonus(participant, blocker)
      expect(result).to eq(0)
    end

    it 'returns +2 per party member who cleared' do
      allow(blocker).to receive(:causes_damage_on_fail?).and_return(true)
      result = described_class.party_bonus(participant, blocker)
      expect(result).to eq(2)
    end

    it 'does not count self in bonus' do
      allow(blocker).to receive(:causes_damage_on_fail?).and_return(true)
      allow(participant).to receive(:has_cleared_blocker?).and_return(true)
      result = described_class.party_bonus(participant, blocker)
      expect(result).to eq(2) # Only other_participant counts
    end
  end
end
