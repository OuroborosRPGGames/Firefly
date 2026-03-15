# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveTrapService do
  let(:room) { instance_double('DelveRoom', id: 1) }
  let(:trap) do
    instance_double('DelveTrap',
                    id: 1,
                    direction: 'north',
                    timing_a: 3,
                    timing_b: 5,
                    damage: 2,
                    trap_theme: 'spikes',
                    description: 'Sharp spikes thrust up from the floor',
                    disabled: false,
                    generate_sequence: [
                      { tick: 0, trapped: false, display: 1 },
                      { tick: 1, trapped: false, display: 2 },
                      { tick: 2, trapped: true, display: 3 }
                    ],
                    safe_at?: true,
                    trigger!: true)
  end
  let(:participant) do
    instance_double('DelveParticipant',
                    spend_time_seconds!: :ok,
                    has_passed_trap?: false,
                    mark_trap_passed!: true,
                    take_hp_damage!: true)
  end

  describe 'class methods' do
    it 'responds to generate!' do
      expect(described_class).to respond_to(:generate!)
    end

    it 'responds to trap_in_direction' do
      expect(described_class).to respond_to(:trap_in_direction)
    end

    it 'responds to get_initial_sequence' do
      expect(described_class).to respond_to(:get_initial_sequence)
    end

    it 'responds to listen_more!' do
      expect(described_class).to respond_to(:listen_more!)
    end

    it 'responds to attempt_passage!' do
      expect(described_class).to respond_to(:attempt_passage!)
    end

    it 'responds to attempt_party_passage!' do
      expect(described_class).to respond_to(:attempt_party_passage!)
    end
  end

  describe '.generate!' do
    before do
      allow(DelveTrap).to receive(:generate_timings).and_return([3, 5])
      allow(DelveTrap).to receive(:random_theme).and_return('spikes')
      allow(DelveTrap).to receive(:create).and_return(trap)
    end

    it 'generates timing values' do
      expect(DelveTrap).to receive(:generate_timings)
      described_class.generate!(room, 'north', 1, :modern)
    end

    it 'selects era-appropriate theme' do
      expect(DelveTrap).to receive(:random_theme).with(:modern)
      described_class.generate!(room, 'north', 1, :modern)
    end

    it 'creates a trap record' do
      expect(DelveTrap).to receive(:create).with(hash_including(
                                                   delve_room_id: room.id,
                                                   direction: 'north',
                                                   damage: 1
                                                 ))
      described_class.generate!(room, 'north', 1, :modern)
    end

    it 'sets damage based on level' do
      expect(DelveTrap).to receive(:create).with(hash_including(damage: 3))
      described_class.generate!(room, 'north', 3, :modern)
    end
  end

  describe '.trap_in_direction' do
    it 'queries for trap in direction' do
      expect(DelveTrap).to receive(:first).with(
        delve_room_id: room.id,
        direction: 'north',
        disabled: false
      )
      described_class.trap_in_direction(room, 'north')
    end
  end

  describe '.get_initial_sequence' do
    it 'returns sequence data' do
      result = described_class.get_initial_sequence(trap)

      expect(result).to include(:start_point, :length, :sequence, :trap_theme, :description, :formatted)
    end

    it 'includes trap theme' do
      result = described_class.get_initial_sequence(trap)
      expect(result[:trap_theme]).to eq('spikes')
    end

    it 'uses deterministic start for participant' do
      result1 = described_class.get_initial_sequence(trap, 100)
      result2 = described_class.get_initial_sequence(trap, 100)

      # Should be the same for same participant
      expect(result1[:start_point]).to eq(result2[:start_point])
    end

    it 'formats sequence for display' do
      result = described_class.get_initial_sequence(trap)
      expect(result[:formatted]).to be_a(String)
    end
  end

  describe '.listen_more!' do
    before do
      allow(trap).to receive(:generate_sequence).and_return([
                                                              { tick: 0, trapped: false, display: 1 },
                                                              { tick: 1, trapped: true, display: 2 }
                                                            ])
    end

    it 'spends time for listening' do
      expect(participant).to receive(:spend_time_seconds!)
      described_class.listen_more!(participant, trap, 0, 5)
    end

    it 'extends the sequence length' do
      result = described_class.listen_more!(participant, trap, 0, 5)
      expect(result[:data][:length]).to be > 5
    end

    it 'returns formatted sequence in message' do
      result = described_class.listen_more!(participant, trap, 0, 5)
      expect(result[:message]).to include('rhythm')
    end
  end

  describe '.attempt_passage!' do
    context 'with invalid passage input' do
      it 'returns error for non-positive pulse numbers' do
        expect(participant).not_to receive(:mark_trap_passed!)

        result = described_class.attempt_passage!(participant, trap, 0, 0)

        expect(result[:success]).to be false
        expect(result[:data][:invalid_pulse]).to be true
      end

      it 'returns error when sequence start is missing' do
        expect(participant).not_to receive(:mark_trap_passed!)

        result = described_class.attempt_passage!(participant, trap, 1, nil)

        expect(result[:success]).to be false
        expect(result[:data][:missing_sequence]).to be true
      end
    end

    context 'when passage is safe' do
      before do
        allow(trap).to receive(:safe_at?).and_return(true)
      end

      it 'marks trap as passed' do
        expect(participant).to receive(:mark_trap_passed!).with(trap.id)
        described_class.attempt_passage!(participant, trap, 1, 0)
      end

      it 'returns success with no damage' do
        result = described_class.attempt_passage!(participant, trap, 1, 0)
        expect(result[:success]).to be true
        expect(result[:data][:safe]).to be true
        expect(result[:data][:damage]).to eq(0)
      end

      it 'includes success message' do
        result = described_class.attempt_passage!(participant, trap, 1, 0)
        expect(result[:message]).to include('perfectly')
      end
    end

    context 'when passage is not safe' do
      before do
        allow(trap).to receive(:safe_at?).and_return(false)
      end

      it 'deals damage to participant' do
        expect(participant).to receive(:take_hp_damage!).with(trap.damage)
        described_class.attempt_passage!(participant, trap, 1, 0)
      end

      it 'triggers the trap' do
        expect(trap).to receive(:trigger!)
        described_class.attempt_passage!(participant, trap, 1, 0)
      end

      it 'returns success (passage completed) but with damage' do
        result = described_class.attempt_passage!(participant, trap, 1, 0)
        expect(result[:success]).to be true
        expect(result[:data][:safe]).to be false
        expect(result[:data][:damage]).to eq(trap.damage)
      end
    end

    context 'experienced passage' do
      it 'passes experienced flag to safe_at?' do
        allow(participant).to receive(:has_passed_trap?).and_return(true)
        expect(trap).to receive(:safe_at?).with(anything, experienced: true)
        described_class.attempt_passage!(participant, trap, 1, 0)
      end
    end
  end

  describe '.attempt_party_passage!' do
    let(:participant2) do
      instance_double('DelveParticipant',
                      has_passed_trap?: false,
                      mark_trap_passed!: true,
                      take_hp_damage!: true,
                      active?: true)
    end

    it 'processes all participants' do
      results = described_class.attempt_party_passage!([participant, participant2], trap, 1, 0)
      expect(results.length).to eq(2)
    end

    it 'marks trap passed for each participant' do
      expect(participant).to receive(:mark_trap_passed!)
      expect(participant2).to receive(:mark_trap_passed!)
      described_class.attempt_party_passage!([participant, participant2], trap, 1, 0)
    end

    it 'triggers the trap for each participant who fails passage' do
      allow(trap).to receive(:safe_at?).and_return(false)
      expect(trap).to receive(:trigger!).twice

      described_class.attempt_party_passage!([participant, participant2], trap, 1, 0)
    end

    it 'marks defeated participants in result data' do
      allow(trap).to receive(:safe_at?).and_return(false)
      frail = instance_double('DelveParticipant',
                              has_passed_trap?: false,
                              mark_trap_passed!: true,
                              take_hp_damage!: true,
                              active?: false)

      results = described_class.attempt_party_passage!([frail], trap, 1, 0)

      expect(results.first[:safe]).to be false
      expect(results.first[:defeated]).to be true
    end
  end

  describe 'trap hit messages' do
    # Test indirectly via attempt_passage! when trap hits
    before do
      allow(trap).to receive(:safe_at?).and_return(false)
    end

    it 'includes theme-specific message for spikes' do
      allow(trap).to receive(:trap_theme).and_return('spikes')
      result = described_class.attempt_passage!(participant, trap, 1, 0)
      expect(result[:message]).to include('Spike')
    end
  end
end
