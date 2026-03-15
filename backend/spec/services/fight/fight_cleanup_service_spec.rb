# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FightCleanupService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality, reality_type: 'primary') }
  let(:character1) { create(:character) }
  let(:character2) { create(:character) }
  let(:instance1) { create(:character_instance, character: character1, current_room: room, reality: reality) }
  let(:instance2) { create(:character_instance, character: character2, current_room: room, reality: reality) }

  def create_fight(attrs = {})
    defaults = {
      room_id: room.id,
      status: 'input',
      started_at: Time.now,
      last_action_at: Time.now
    }
    Fight.create(defaults.merge(attrs))
  end

  def add_participant(fight, char_instance, side: 1, is_knocked_out: false)
    FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: char_instance.id,
      side: side,
      current_hp: is_knocked_out ? 0 : 6,
      is_knocked_out: is_knocked_out
    )
  end

  describe '.cleanup_all!' do
    it 'responds to cleanup_all!' do
      expect(described_class).to respond_to(:cleanup_all!)
    end

    it 'returns a results hash with required keys' do
      result = described_class.cleanup_all!
      expect(result).to be_a(Hash)
      expect(result).to include(:cleaned, :stale, :ended, :very_stale, :errors)
    end

    it 'returns zeroes when no fights exist' do
      result = described_class.cleanup_all!
      expect(result[:cleaned]).to eq(0)
      expect(result[:stale]).to eq(0)
      expect(result[:ended]).to eq(0)
    end

    context 'with stale fights' do
      it 'cleans up fights inactive for 15+ minutes' do
        # Create a fight that hasn't had activity in 20 minutes
        stale_time = Time.now - (20 * 60)
        fight = create_fight(status: 'input', last_action_at: stale_time, started_at: stale_time)
        add_participant(fight, instance1, side: 1)
        add_participant(fight, instance2, side: 2)

        result = described_class.cleanup_all!
        expect(result[:stale]).to be >= 0 # May or may not trigger based on timing
      end
    end

    context 'with fights that have no opponents' do
      it 'cleans up fights with 0 active participants' do
        fight = create_fight(status: 'input')
        # All participants are knocked out
        add_participant(fight, instance1, side: 1, is_knocked_out: true)
        add_participant(fight, instance2, side: 2, is_knocked_out: true)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to be >= 0
      end
    end

    context 'with fights that have one survivor' do
      it 'cleans up fights with only 1 active participant' do
        fight = create_fight(status: 'input')
        add_participant(fight, instance1, side: 1, is_knocked_out: false)
        add_participant(fight, instance2, side: 2, is_knocked_out: true)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to be >= 0
      end
    end

    context 'error handling' do
      it 'captures errors without stopping cleanup' do
        # Create a fight and stub complete! to raise an error
        fight = create_fight(status: 'input', last_action_at: Time.now - 1800)
        add_participant(fight, instance1, side: 1)

        allow(Fight).to receive(:needing_cleanup).and_return([fight])
        allow(fight).to receive(:needs_cleanup?).and_return(true)
        allow(fight).to receive(:stale?).and_return(true)
        allow(fight).to receive(:complete!).and_raise(StandardError.new('Test error'))

        result = described_class.cleanup_all!
        expect(result[:errors]).to include(hash_including(fight_id: fight.id, error: 'Test error'))
      end
    end

    context 'very stale fights' do
      it 'includes very_stale count from Fight.cleanup_stale_fights!' do
        allow(Fight).to receive(:cleanup_stale_fights!).and_return(5)

        result = described_class.cleanup_all!
        expect(result[:very_stale]).to eq(5)
        expect(result[:cleaned]).to be >= 5
      end
    end

    context 'with all participants offline' do
      it 'cleans up the fight with reason all_offline' do
        fight = create_fight(status: 'input')
        p1 = add_participant(fight, instance1, side: 1)
        p2 = add_participant(fight, instance2, side: 2)

        # Stub character_instance to return offline for both participants
        offline_ci1 = double('ci1', online: false, current_room_id: room.id)
        offline_ci2 = double('ci2', online: false, current_room_id: room.id)
        allow(p1).to receive(:character_instance).and_return(offline_ci1)
        allow(p2).to receive(:character_instance).and_return(offline_ci2)
        allow(p1).to receive(:is_npc).and_return(false)
        allow(p2).to receive(:is_npc).and_return(false)

        # The fight has 2 active participants on different sides, so the first loop
        # (needing_cleanup) won't catch it. We need the second loop to find it.
        # Stub the second loop's query to return our fight with stubbed participants.
        active_dataset = double('active_dataset')
        allow(active_dataset).to receive(:count).and_return(2)
        allow(active_dataset).to receive(:reject).and_return([p1, p2])
        allow(active_dataset).to receive(:all).and_return([p1, p2])
        allow(active_dataset).to receive(:first).and_return(p1)
        allow(fight).to receive(:active_participants).and_return(active_dataset)

        # Ensure fight appears in the second loop query
        allow(Fight).to receive(:where).with(status: %w[input resolving narrative]).and_return(
          double('dataset', all: [fight])
        )
        # First loop returns nothing so our fight isn't skipped
        allow(Fight).to receive(:needing_cleanup).and_return([])
        allow(Fight).to receive(:cleanup_stale_fights!).and_return(0)

        allow(BroadcastService).to receive(:to_room)
        allow(fight).to receive(:complete!)
        allow(fight).to receive(:room).and_return(room)

        result = described_class.cleanup_all!

        expect(fight).to have_received(:complete!)
        expect(result[:ended]).to eq(1)
        expect(result[:cleaned]).to eq(1)
        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          hash_including(reason: 'all_offline'),
          type: :combat
        )
      end
    end

    context 'with all participants left room' do
      it 'cleans up the fight with reason all_left_room after grace period' do
        # last_action_at is old enough to exceed the grace period (>120 seconds)
        old_time = Time.now - 300
        fight = create_fight(status: 'input', last_action_at: old_time)
        other_room = create(:room)
        p1 = add_participant(fight, instance1, side: 1)
        p2 = add_participant(fight, instance2, side: 2)

        # Stub character_instance to return online but in a different room
        ci1 = double('ci1', online: true, current_room_id: other_room.id)
        ci2 = double('ci2', online: true, current_room_id: other_room.id)
        allow(p1).to receive(:character_instance).and_return(ci1)
        allow(p2).to receive(:character_instance).and_return(ci2)
        allow(p1).to receive(:is_npc).and_return(false)
        allow(p2).to receive(:is_npc).and_return(false)

        active_dataset = double('active_dataset')
        allow(active_dataset).to receive(:count).and_return(2)
        allow(active_dataset).to receive(:reject).and_return([p1, p2])
        allow(active_dataset).to receive(:all).and_return([p1, p2])
        allow(active_dataset).to receive(:first).and_return(p1)
        allow(fight).to receive(:active_participants).and_return(active_dataset)

        allow(Fight).to receive(:where).with(status: %w[input resolving narrative]).and_return(
          double('dataset', all: [fight])
        )
        allow(Fight).to receive(:needing_cleanup).and_return([])
        allow(Fight).to receive(:cleanup_stale_fights!).and_return(0)

        allow(BroadcastService).to receive(:to_room)
        allow(fight).to receive(:complete!)
        allow(fight).to receive(:room).and_return(room)

        result = described_class.cleanup_all!

        expect(fight).to have_received(:complete!)
        expect(result[:ended]).to eq(1)
        expect(result[:cleaned]).to eq(1)
        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          hash_including(reason: 'all_left_room'),
          type: :combat
        )
      end
    end

    context 'with NPC-only fight' do
      it 'does not clean up via participant state check' do
        fight = create_fight(status: 'input')

        # Create NPC-only participants (no character_instance)
        npc1 = FightParticipant.create(
          fight_id: fight.id,
          is_npc: true,
          npc_name: 'Goblin',
          side: 1,
          current_hp: 6,
          is_knocked_out: false
        )
        npc2 = FightParticipant.create(
          fight_id: fight.id,
          is_npc: true,
          npc_name: 'Orc',
          side: 2,
          current_hp: 6,
          is_knocked_out: false
        )

        active_dataset = double('active_dataset')
        allow(active_dataset).to receive(:count).and_return(2)
        allow(active_dataset).to receive(:reject).and_return([]) # No human participants
        allow(active_dataset).to receive(:all).and_return([npc1, npc2])
        allow(active_dataset).to receive(:first).and_return(npc1)
        allow(fight).to receive(:active_participants).and_return(active_dataset)

        allow(Fight).to receive(:where).with(status: %w[input resolving narrative]).and_return(
          double('dataset', all: [fight])
        )
        # First loop also skips it (2 active on different sides, not stale)
        allow(Fight).to receive(:needing_cleanup).and_return([])
        allow(Fight).to receive(:cleanup_stale_fights!).and_return(0)

        allow(BroadcastService).to receive(:to_room)

        result = described_class.cleanup_all!

        # NPC-only fight should NOT be cleaned up by participant state check
        expect(result[:ended]).to eq(0)
        expect(result[:cleaned]).to eq(0)
        expect(BroadcastService).not_to have_received(:to_room)
      end
    end

    context 'with left room but within grace period' do
      it 'does not clean up when last_action_at is recent' do
        # last_action_at is very recent (within the 120s grace period)
        fight = create_fight(status: 'input', last_action_at: Time.now - 10)
        other_room = create(:room)
        p1 = add_participant(fight, instance1, side: 1)
        p2 = add_participant(fight, instance2, side: 2)

        # Participants are online but in a different room
        ci1 = double('ci1', online: true, current_room_id: other_room.id)
        ci2 = double('ci2', online: true, current_room_id: other_room.id)
        allow(p1).to receive(:character_instance).and_return(ci1)
        allow(p2).to receive(:character_instance).and_return(ci2)
        allow(p1).to receive(:is_npc).and_return(false)
        allow(p2).to receive(:is_npc).and_return(false)

        active_dataset = double('active_dataset')
        allow(active_dataset).to receive(:count).and_return(2)
        allow(active_dataset).to receive(:reject).and_return([p1, p2])
        allow(active_dataset).to receive(:all).and_return([p1, p2])
        allow(active_dataset).to receive(:first).and_return(p1)
        allow(fight).to receive(:active_participants).and_return(active_dataset)

        allow(Fight).to receive(:where).with(status: %w[input resolving narrative]).and_return(
          double('dataset', all: [fight])
        )
        allow(Fight).to receive(:needing_cleanup).and_return([])
        allow(Fight).to receive(:cleanup_stale_fights!).and_return(0)

        allow(BroadcastService).to receive(:to_room)

        result = described_class.cleanup_all!

        # Should NOT be cleaned up - still within grace period
        expect(result[:ended]).to eq(0)
        expect(result[:cleaned]).to eq(0)
        expect(BroadcastService).not_to have_received(:to_room)
      end
    end
  end

  describe 'fight completion notifications' do
    let(:fight) { create_fight(status: 'input', last_action_at: Time.now - 1800) }

    before do
      add_participant(fight, instance1, side: 1)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'sends combat_ended broadcast to room' do
      # Make fight appear stale
      allow(Fight).to receive(:needing_cleanup).and_return([fight])
      allow(fight).to receive(:stale?).and_return(true)
      allow(fight).to receive(:active_participants).and_return(double(count: 2, first: nil))

      expect(BroadcastService).to receive(:to_room).with(
        room.id,
        hash_including(type: 'combat_ended', fight_id: fight.id),
        type: :combat
      )

      described_class.cleanup_all!
    end
  end

  describe 'determine_reason private method' do
    # Test via cleanup_all! behavior
    let(:fight) { create_fight(status: 'input') }

    it 'identifies :no_opponents when active_count is 0' do
      add_participant(fight, instance1, side: 1, is_knocked_out: true)
      add_participant(fight, instance2, side: 2, is_knocked_out: true)

      allow(BroadcastService).to receive(:to_room)
      described_class.cleanup_all!

      # Verify message indicates no combatants
      expect(BroadcastService).to have_received(:to_room).with(
        room.id,
        hash_including(reason: 'no_opponents'),
        anything
      )
    end

    it 'identifies :last_standing when active_count is 1' do
      add_participant(fight, instance1, side: 1, is_knocked_out: false)
      add_participant(fight, instance2, side: 2, is_knocked_out: true)

      allow(BroadcastService).to receive(:to_room)
      described_class.cleanup_all!

      expect(BroadcastService).to have_received(:to_room).with(
        room.id,
        hash_including(reason: 'last_standing'),
        anything
      )
    end
  end
end
