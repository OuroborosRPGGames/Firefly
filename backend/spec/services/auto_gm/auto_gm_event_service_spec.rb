# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmEventService do
  include_context 'auto_gm_session_dataset'

  describe 'EVENT_FOCUS' do
    it 'has 11 focus types' do
      expect(described_class::EVENT_FOCUS.length).to eq(11)
    end

    it 'covers the full d100 range' do
      all_values = described_class::EVENT_FOCUS.flat_map { |f| f[:range].to_a }
      expect(all_values.min).to eq(1)
      expect(all_values.max).to eq(100)
    end

    it 'has no gaps in ranges' do
      ranges = described_class::EVENT_FOCUS.map { |f| f[:range] }
      expected = 1
      ranges.each do |range|
        expect(range.first).to eq(expected)
        expected = range.last + 1
      end
    end

    it 'includes remote_event focus' do
      focus = described_class::EVENT_FOCUS.find { |f| f[:focus] == :remote_event }
      expect(focus).not_to be_nil
      expect(focus[:range]).to eq(1..7)
    end

    it 'includes npc_action focus' do
      focus = described_class::EVENT_FOCUS.find { |f| f[:focus] == :npc_action }
      expect(focus).not_to be_nil
    end

    it 'includes pc_negative and pc_positive focus' do
      negative = described_class::EVENT_FOCUS.find { |f| f[:focus] == :pc_negative }
      positive = described_class::EVENT_FOCUS.find { |f| f[:focus] == :pc_positive }
      expect(negative).not_to be_nil
      expect(positive).not_to be_nil
    end
  end

  describe '.check_random_event' do
    let(:action_dataset) do
      double('Dataset',
             max: 0)
    end

    before do
      allow(session).to receive(:auto_gm_actions_dataset).and_return(action_dataset)
      allow(AutoGmAction).to receive(:create_with_next_sequence).and_return(action)
      allow(action).to receive(:mark_completed!)
    end

    context 'when roll triggers event (doubles rule)' do
      it 'triggers on 11 with chaos 1' do
        result = described_class.check_random_event(session, 11)
        expect(result).not_to be_nil
      end

      it 'triggers on 22 with chaos 5' do
        result = described_class.check_random_event(session, 22)
        expect(result).not_to be_nil
      end

      it 'triggers on 55 with chaos 5' do
        result = described_class.check_random_event(session, 55)
        expect(result).not_to be_nil
      end

      it 'triggers on 33 with chaos 5' do
        result = described_class.check_random_event(session, 33)
        expect(result).not_to be_nil
      end
    end

    context 'when roll does not trigger event' do
      it 'returns nil for non-doubles' do
        expect(described_class.check_random_event(session, 25)).to be_nil
      end

      it 'returns nil when tens digit > chaos' do
        allow(session).to receive(:chaos_level).and_return(3)
        expect(described_class.check_random_event(session, 44)).to be_nil
      end

      it 'returns nil for 66 with chaos 5' do
        expect(described_class.check_random_event(session, 66)).to be_nil
      end

      it 'returns nil for 99 with chaos 5' do
        expect(described_class.check_random_event(session, 99)).to be_nil
      end
    end

    context 'with high chaos (9)' do
      before do
        allow(session).to receive(:chaos_level).and_return(9)
      end

      it 'triggers on 88' do
        result = described_class.check_random_event(session, 88)
        expect(result).not_to be_nil
      end

      it 'triggers on 99' do
        result = described_class.check_random_event(session, 99)
        expect(result).not_to be_nil
      end
    end

    context 'with low chaos (1)' do
      before do
        allow(session).to receive(:chaos_level).and_return(1)
      end

      it 'triggers only on 11' do
        expect(described_class.check_random_event(session, 11)).not_to be_nil
      end

      it 'does not trigger on 22' do
        expect(described_class.check_random_event(session, 22)).to be_nil
      end
    end

    context 'event creation' do
      it 'creates AutoGmAction with emit type' do
        expect(AutoGmAction).to receive(:create_with_next_sequence).with(
          session_id: session.id,
          attributes: hash_including(
            action_type: 'emit',
            status: 'pending'
          )
        )

        described_class.check_random_event(session, 11)
      end

      it 'broadcasts the event' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(type: 'auto_gm_random_event'),
          hash_including(type: :auto_gm_random_event)
        )

        described_class.check_random_event(session, 11)
      end
    end
  end

  describe '.force_event' do
    let(:action_dataset) do
      double('Dataset', max: 0)
    end

    before do
      allow(session).to receive(:auto_gm_actions_dataset).and_return(action_dataset)
      allow(AutoGmAction).to receive(:create_with_next_sequence).and_return(action)
      allow(action).to receive(:mark_completed!)
    end

    it 'creates an event regardless of chaos/roll' do
      result = described_class.force_event(session)
      expect(result).not_to be_nil
    end

    context 'with specific focus' do
      it 'uses the specified focus' do
        expect(AutoGmAction).to receive(:create_with_next_sequence).with(
          session_id: session.id,
          attributes: hash_including(action_data: hash_including(focus: 'npc_action'))
        )

        described_class.force_event(session, focus: :npc_action)
      end

      it 'uses pc_positive focus' do
        expect(AutoGmAction).to receive(:create_with_next_sequence).with(
          session_id: session.id,
          attributes: hash_including(action_data: hash_including(focus: 'pc_positive'))
        )

        described_class.force_event(session, focus: :pc_positive)
      end
    end
  end

  describe '.adjust_chaos' do
    context 'when PCs are in control' do
      it 'decreases chaos by 1' do
        expect(session).to receive(:adjust_chaos!).with(-1)
        described_class.adjust_chaos(session, pc_in_control: true)
      end

      context 'when chaos is already at minimum (1)' do
        before do
          allow(session).to receive(:chaos_level).and_return(1)
        end

        it 'does not adjust chaos' do
          expect(session).not_to receive(:adjust_chaos!)
          described_class.adjust_chaos(session, pc_in_control: true)
        end
      end
    end

    context 'when PCs are not in control' do
      it 'increases chaos by 1' do
        expect(session).to receive(:adjust_chaos!).with(1)
        described_class.adjust_chaos(session, pc_in_control: false)
      end

      context 'when chaos is already at maximum (9)' do
        before do
          allow(session).to receive(:chaos_level).and_return(9)
        end

        it 'does not adjust chaos' do
          expect(session).not_to receive(:adjust_chaos!)
          described_class.adjust_chaos(session, pc_in_control: false)
        end
      end
    end
  end

  describe '.focus_for_roll' do
    it 'returns remote_event for roll 1-7' do
      (1..7).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:remote_event)
      end
    end

    it 'returns npc_action for roll 8-28' do
      (8..28).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:npc_action)
      end
    end

    it 'returns introduce_npc for roll 29-35' do
      (29..35).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:introduce_npc)
      end
    end

    it 'returns move_toward for roll 36-45' do
      (36..45).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:move_toward)
      end
    end

    it 'returns move_away for roll 46-52' do
      (46..52).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:move_away)
      end
    end

    it 'returns close_thread for roll 53-55' do
      (53..55).each do |roll|
        result = described_class.focus_for_roll(roll)
        expect(result[:focus]).to eq(:close_thread)
      end
    end

    it 'returns pc_negative for roll 56-67' do
      expect(described_class.focus_for_roll(56)[:focus]).to eq(:pc_negative)
      expect(described_class.focus_for_roll(67)[:focus]).to eq(:pc_negative)
    end

    it 'returns pc_positive for roll 68-75' do
      expect(described_class.focus_for_roll(68)[:focus]).to eq(:pc_positive)
      expect(described_class.focus_for_roll(75)[:focus]).to eq(:pc_positive)
    end

    it 'returns ambiguous for roll 76-83' do
      expect(described_class.focus_for_roll(76)[:focus]).to eq(:ambiguous)
      expect(described_class.focus_for_roll(83)[:focus]).to eq(:ambiguous)
    end

    it 'returns npc_negative for roll 84-92' do
      expect(described_class.focus_for_roll(84)[:focus]).to eq(:npc_negative)
      expect(described_class.focus_for_roll(92)[:focus]).to eq(:npc_negative)
    end

    it 'returns npc_positive for roll 93-100' do
      expect(described_class.focus_for_roll(93)[:focus]).to eq(:npc_positive)
      expect(described_class.focus_for_roll(100)[:focus]).to eq(:npc_positive)
    end
  end

  describe 'private methods' do
    describe '#should_trigger?' do
      it 'returns true for doubles when tens <= chaos' do
        # chaos = 5, so 11, 22, 33, 44, 55 should trigger
        expect(described_class.send(:should_trigger?, 11, 5)).to be true
        expect(described_class.send(:should_trigger?, 55, 5)).to be true
      end

      it 'returns false for non-doubles' do
        expect(described_class.send(:should_trigger?, 12, 9)).to be false
        expect(described_class.send(:should_trigger?, 56, 9)).to be false
      end

      it 'returns false when tens > chaos' do
        expect(described_class.send(:should_trigger?, 66, 5)).to be false
        expect(described_class.send(:should_trigger?, 77, 5)).to be false
      end

      it 'handles edge case of 00 (100)' do
        # 100 is tens=10, ones=0, not doubles
        expect(described_class.send(:should_trigger?, 100, 9)).to be false
      end
    end

    describe '#focus_specific_instruction' do
      it 'returns instruction for remote_event' do
        result = described_class.send(:focus_specific_instruction, :remote_event)
        expect(result).to include('elsewhere')
      end

      it 'returns instruction for npc_action' do
        result = described_class.send(:focus_specific_instruction, :npc_action)
        expect(result).to include('NPC')
      end

      it 'returns instruction for pc_negative' do
        result = described_class.send(:focus_specific_instruction, :pc_negative)
        expect(result).to include('unfortunate')
      end

      it 'returns instruction for pc_positive' do
        result = described_class.send(:focus_specific_instruction, :pc_positive)
        expect(result).to include('lucky')
      end

      it 'returns default for unknown focus' do
        result = described_class.send(:focus_specific_instruction, :unknown)
        expect(result).to include('dramatic')
      end
    end
  end
end
