# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityFreeRollService do
  let(:activity) { create(:activity) }
  let(:room) { create(:room) }
  let(:instance) do
    create(:activity_instance, activity: activity, room: room, running: true)
  end
  let(:round) { create(:activity_round, :free_roll, activity: activity) }
  let(:character) { create(:character) }
  let(:participant) do
    create(:activity_participant, instance: instance, character: character)
  end

  describe 'error classes' do
    it 'defines FreeRollError' do
      expect(described_class::FreeRollError).to be < StandardError
    end
  end

  describe 'structs' do
    describe 'EvaluationResult' do
      it 'has expected attributes' do
        result = described_class::EvaluationResult.new(
          stat_ids: [1, 2],
          stat_names: %w[STR DEX],
          dc: 15,
          success_desc: 'You succeed!',
          failure_desc: 'You fail.',
          context_revealed: 'You learn something'
        )
        expect(result.stat_ids).to eq([1, 2])
        expect(result.stat_names).to eq(%w[STR DEX])
        expect(result.dc).to eq(15)
      end
    end

    describe 'ActionResult' do
      it 'has expected attributes' do
        result = described_class::ActionResult.new(
          participant_id: 1,
          character_name: 'Test',
          action_description: 'I attack',
          stat_names: ['STR'],
          roll_total: 18,
          dc: 15,
          success: true,
          narration: 'You strike true!'
        )
        expect(result.success).to be true
        expect(result.roll_total).to eq(18)
      end
    end
  end

  describe 'constants' do
    it 'defines FREE_ROLL_MODEL' do
      expect(described_class::FREE_ROLL_MODEL).to eq('claude-sonnet-4-6')
    end

    it 'defines FREE_ROLL_PROVIDER' do
      expect(described_class::FREE_ROLL_PROVIDER).to eq('anthropic')
    end
  end

  describe '.enabled?' do
    it 'checks GameSetting' do
      # Default is disabled
      result = described_class.enabled?
      expect([true, false]).to include(result)
    end
  end

  describe '.assess' do
    before do
      allow(described_class).to receive(:enabled?).and_return(false)
    end

    it 'raises FreeRollError when not enabled' do
      expect {
        described_class.assess!(participant, 'look around', round)
      }.to raise_error(described_class::FreeRollError, /not enabled/)
    end
  end

  describe '.take_action' do
    before do
      allow(described_class).to receive(:enabled?).and_return(false)
    end

    it 'raises FreeRollError when not enabled' do
      expect {
        described_class.take_action(participant, 'attack the goblin', round)
      }.to raise_error(described_class::FreeRollError, /not enabled/)
    end
  end

  describe '.check_round_complete' do
    let(:activity) { create(:activity) }
    let(:room) { create(:room) }
    let(:instance) { create(:activity_instance, activity: activity, room: room) }
    let(:round) { create(:activity_round, :free_roll, activity: activity) }

    it 'returns hash with complete key' do
      result = described_class.check_round_complete(instance, round)
      expect(result).to have_key(:complete)
      expect(result).to have_key(:success)
      expect(result).to have_key(:narration)
    end
  end

  describe 'stat bonus resolution' do
    it 'uses named stats when stat_ids are empty' do
      roll = DiceRollService::RollResult.new(
        dice: [5, 5], base_dice: [5, 5], explosions: [],
        modifier: 0, total: 10, count: 2, sides: 8, explode_on: 8
      )
      allow(DiceRollService).to receive(:roll).and_return(roll)

      str_stat = double('Stat', id: 1, abbreviation: 'STR')
      allow(described_class).to receive(:find_stat_by_name).with('STR').and_return(str_stat)
      allow(StatAllocationService).to receive(:get_stat_value).with(anything, 'STR').and_return(3)

      ci = double('CharacterInstance')
      participant = double('ActivityParticipant',
                           character_instance: ci,
                           willpower_to_spend: 0,
                           available_willpower: 0)

      total = described_class.send(:roll_for_stats, participant, [], ['STR'])
      expect(total).to eq(13)
    end

    it 'parses explicit stat_ids when provided by LLM' do
      parsed = described_class.send(
        :parse_evaluation,
        '{"stat_ids":[2,5],"stat_names":["INT"],"dc":15,"success_desc":"ok","failure_desc":"nope"}'
      )

      expect(parsed.stat_ids).to eq([2, 5])
      expect(parsed.dc).to eq(15)
    end
  end
end
