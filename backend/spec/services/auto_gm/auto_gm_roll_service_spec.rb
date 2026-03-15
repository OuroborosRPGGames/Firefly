# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmRollService do
  include_context 'auto_gm_session_dataset'

  let(:roll_result) do
    { total: 15, dice: [6, 5, 4], modifier: 0 }
  end

  let(:roll_request_action) do
    double('AutoGmAction',
           id: 1,
           action_type: 'roll_request',
           status: 'completed',
           action_data: {
             'roll_pending' => true,
             'roll_targets' => [char_instance.id],
             'roll_dc' => 12,
             'roll_stat' => 'physical',
             'roll_type' => 'strength check'
           },
           update: true)
  end

  before do
    allow(DisplayHelper).to receive(:character_display_name).and_return('Test Hero')
  end

  describe '.process_roll' do
    context 'when no active session' do
      before do
        allow(AutoGmSession).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', first: nil))
        )
      end

      it 'returns not processed with reason' do
        result = described_class.process_roll(char_instance, roll_result, 'physical')

        expect(result[:processed]).to be false
        expect(result[:reason]).to eq('No active Auto-GM session')
      end
    end

    context 'when no pending roll request' do
      before do
        allow(AutoGmSession).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', first: session))
        )
        allow(auto_gm_actions_dataset).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', order: double('Dataset', all: [])))
        )
      end

      it 'returns not processed with reason' do
        result = described_class.process_roll(char_instance, roll_result, 'physical')

        expect(result[:processed]).to be false
        expect(result[:reason]).to eq('No pending roll request')
      end
    end

    context 'with active session and pending roll' do
      before do
        allow(AutoGmSession).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', first: session))
        )
        allow(auto_gm_actions_dataset).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', order: double('Dataset', all: [roll_request_action])))
        )
        allow(roll_request_action).to receive(:action_data).and_return({
          'roll_pending' => true,
          'roll_targets' => [char_instance.id],
          'roll_dc' => 12,
          'roll_stat' => 'physical',
          'roll_type' => 'strength check',
          'roll_results' => {}
        })
      end

      context 'when roll succeeds' do
        let(:roll_result) { { total: 15 } }

        it 'returns processed true' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:processed]).to be true
        end

        it 'returns success true when total >= DC' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:success]).to be true
        end

        it 'returns roll total' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:total]).to eq(15)
        end

        it 'returns the DC' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:dc]).to eq(12)
        end

        it 'returns margin' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:margin]).to eq(3) # 15 - 12
        end
      end

      context 'when roll fails' do
        let(:roll_result) { { total: 8 } }

        it 'returns success false when total < DC' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:success]).to be false
        end

        it 'returns negative margin' do
          result = described_class.process_roll(char_instance, roll_result, 'physical')
          expect(result[:margin]).to eq(-4) # 8 - 12
        end
      end

      context 'with object-style roll result' do
        let(:roll_object) { double('DiceRollResult', total: 18) }

        it 'extracts total from object' do
          result = described_class.process_roll(char_instance, roll_object, 'physical')
          expect(result[:total]).to eq(18)
        end
      end

      context 'when roll request specifies an exact stat id' do
        let!(:requested_stat) { create(:stat, name: 'Physical', abbreviation: 'PHY') }

        before do
          allow(roll_request_action).to receive(:action_data).and_return({
            'roll_pending' => true,
            'roll_targets' => [char_instance.id],
            'roll_dc' => 12,
            'roll_stat' => 'physical',
            'roll_stat_id' => requested_stat.id,
            'roll_type' => 'strength check',
            'roll_results' => {}
          })
        end

        it 'rejects rolls using a different stat' do
          expect(roll_request_action).not_to receive(:update)

          result = described_class.process_roll(char_instance, { total: 15 }, 'mental')

          expect(result[:processed]).to be false
          expect(result[:reason]).to eq('Roll stat mismatch')
          expect(result[:expected_stat]).to eq('Physical')
        end
      end
    end
  end

  describe '.pending_roll_requests' do
    let(:jsonb_op) { double('JSONBOp') }
    let(:jsonb_condition) { double('Condition') }

    before do
      # Stub Sequel.pg_jsonb_op to handle JSON queries
      allow(Sequel).to receive(:pg_jsonb_op).with(:action_data).and_return(jsonb_op)
      allow(jsonb_op).to receive(:contains).and_return(jsonb_condition)
    end

    it 'queries actions dataset for roll_request type' do
      final_dataset = double('Dataset', all: [])
      type_filtered = double('Dataset', where: final_dataset)
      allow(auto_gm_actions_dataset).to receive(:where).with(action_type: 'roll_request').and_return(type_filtered)

      result = described_class.pending_roll_requests(session)
      expect(result).to eq([])
    end

    it 'filters for roll_pending true' do
      final_dataset = double('Dataset', all: [roll_request_action])
      type_filtered = double('Dataset', where: final_dataset)
      allow(auto_gm_actions_dataset).to receive(:where).with(action_type: 'roll_request').and_return(type_filtered)

      result = described_class.pending_roll_requests(session)
      expect(result).to include(roll_request_action)
    end
  end

  describe 'private methods' do
    describe '#extract_roll_total' do
      it 'extracts from object with total method' do
        obj = double('DiceRoll', total: 20)
        result = described_class.send(:extract_roll_total, obj)
        expect(result).to eq(20)
      end

      it 'extracts from hash with symbol key' do
        result = described_class.send(:extract_roll_total, { total: 15 })
        expect(result).to eq(15)
      end

      it 'extracts from hash with string key' do
        result = described_class.send(:extract_roll_total, { 'total' => 12 })
        expect(result).to eq(12)
      end

      it 'returns nil for invalid input' do
        result = described_class.send(:extract_roll_total, 'invalid')
        expect(result).to be_nil
      end
    end

    describe '#update_action_with_result' do
      let(:action_data) do
        {
          'roll_pending' => true,
          'roll_targets' => [char_instance.id],
          'roll_dc' => 12,
          'roll_results' => {}
        }
      end

      before do
        allow(roll_request_action).to receive(:action_data).and_return(action_data)
      end

      it 'stores roll result for character' do
        expect(roll_request_action).to receive(:update) do |args|
          results = args[:action_data]['roll_results']
          expect(results[char_instance.id.to_s]['total']).to eq(15)
          expect(results[char_instance.id.to_s]['success']).to be true
        end

        described_class.send(:update_action_with_result, roll_request_action, char_instance, 15, true, 3, 'physical')
      end

      it 'includes character name in result' do
        expect(roll_request_action).to receive(:update) do |args|
          results = args[:action_data]['roll_results']
          expect(results[char_instance.id.to_s]['character_name']).to eq('Test Hero')
        end

        described_class.send(:update_action_with_result, roll_request_action, char_instance, 15, true, 3, 'physical')
      end

      it 'marks roll_pending false when all targets have rolled' do
        expect(roll_request_action).to receive(:update) do |args|
          expect(args[:action_data]['roll_pending']).to be false
        end

        described_class.send(:update_action_with_result, roll_request_action, char_instance, 15, true, 3, 'physical')
      end
    end

    describe '#check_all_rolls_complete' do
      it 'returns true when roll_pending is false' do
        allow(roll_request_action).to receive(:action_data).and_return({ 'roll_pending' => false })
        result = described_class.send(:check_all_rolls_complete, roll_request_action)
        expect(result).to be true
      end

      it 'returns false when roll_pending is true' do
        allow(roll_request_action).to receive(:action_data).and_return({ 'roll_pending' => true })
        result = described_class.send(:check_all_rolls_complete, roll_request_action)
        expect(result).to be false
      end

      it 'returns true when action_data is nil' do
        allow(roll_request_action).to receive(:action_data).and_return(nil)
        result = described_class.send(:check_all_rolls_complete, roll_request_action)
        expect(result).to be true
      end
    end
  end
end
