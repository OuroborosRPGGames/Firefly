# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Fight do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Battle Room', short_description: 'A room', room_type: 'standard') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { Character.create(forename: 'Fighter', surname: 'One', user: user, is_npc: false) }
  let(:character_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      level: 1,
      experience: 0,
      health: 100,
      max_health: 100,
      mana: 50,
      max_mana: 50
    )
  end

  describe 'validations' do
    it 'requires room_id' do
      fight = Fight.new(status: 'input')
      expect(fight.valid?).to be false
      expect(fight.errors[:room_id]).to include('is not present')
    end

    it 'validates status is in STATUSES' do
      fight = Fight.new(room_id: room.id, status: 'invalid_status')
      expect(fight.valid?).to be false
      expect(fight.errors[:status]).not_to be_empty
    end

    it 'accepts valid statuses' do
      Fight::STATUSES.each do |status|
        fight = Fight.new(room_id: room.id, status: status)
        fight.valid?
        # Sequel returns nil for keys without errors, not empty array
        expect(fight.errors[:status]).to be_nil
      end
    end
  end

  describe 'before_create' do
    it 'sets default values' do
      fight = Fight.create(room_id: room.id)

      expect(fight.started_at).not_to be_nil
      expect(fight.last_action_at).not_to be_nil
      expect(fight.round_number).to eq(1)
      expect(fight.status).to eq('input')
      expect(fight.input_deadline_at).not_to be_nil
    end

    it 'calculates arena dimensions from room bounds' do
      room.update(min_x: 0, max_x: 40, min_y: 0, max_y: 40)
      fight = Fight.create(room_id: room.id)

      expect(fight.arena_width).to be > 0
      expect(fight.arena_height).to be > 0
    end
  end

  describe '#input_timed_out?' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'returns false when deadline not reached' do
      expect(fight.input_timed_out?).to be false
    end

    it 'returns true when deadline passed' do
      fight.update(input_deadline_at: Time.now - 60)
      expect(fight.input_timed_out?).to be true
    end
  end

  describe '#all_inputs_complete?' do
    let(:fight) { Fight.create(room_id: room.id) }

    before do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        input_complete: false,
        is_knocked_out: false
      )
    end

    it 'returns false when participants have not completed input' do
      expect(fight.all_inputs_complete?).to be false
    end

    it 'returns true when all active participants completed input' do
      fight.fight_participants.first.update(input_complete: true)
      expect(fight.all_inputs_complete?).to be true
    end
  end

  describe '#active_participants' do
    let(:fight) { Fight.create(room_id: room.id) }

    let(:user2) { create(:user) }
    let(:character2) { Character.create(forename: 'Fighter', surname: 'Two', user: user2, is_npc: false) }
    let(:character_instance2) do
      CharacterInstance.create(
        character: character2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
    end

    before do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance2,
        current_hp: 0,
        max_hp: 6,
        side: 2,
        is_knocked_out: true
      )
    end

    it 'returns only non-knocked-out participants' do
      expect(fight.active_participants.count).to eq(1)
      expect(fight.active_participants.first.character_instance_id).to eq(character_instance.id)
    end
  end

  describe '#ongoing?' do
    it 'returns true for input status' do
      fight = Fight.create(room_id: room.id, status: 'input')
      expect(fight.ongoing?).to be true
    end

    it 'returns true for resolving status' do
      fight = Fight.create(room_id: room.id, status: 'resolving')
      expect(fight.ongoing?).to be true
    end

    it 'returns false for complete status' do
      fight = Fight.create(room_id: room.id, status: 'complete')
      expect(fight.ongoing?).to be false
    end
  end

  describe '#should_end?' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'returns false with multiple active participants' do
      user2 = create(:user)
      char2 = Character.create(forename: 'Fighter', surname: 'Two', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )

      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )
      FightParticipant.create(
        fight: fight,
        character_instance: instance2,
        current_hp: 6,
        max_hp: 6,
        side: 2,
        is_knocked_out: false
      )

      expect(fight.should_end?).to be false
    end

    it 'returns true with one or zero active participants' do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )

      expect(fight.should_end?).to be true
    end

    it 'returns false when fight is not ongoing' do
      fight.update(status: 'complete')
      expect(fight.should_end?).to be false
    end
  end

  describe '#stale?' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'returns false for recent fight' do
      expect(fight.stale?).to be false
    end

    it 'returns true for fight with no activity for 15+ minutes' do
      fight.update(last_action_at: Time.now - 1000)
      expect(fight.stale?).to be true
    end

    it 'returns false for completed fight' do
      fight.update(status: 'complete', last_action_at: Time.now - 1000)
      expect(fight.stale?).to be false
    end
  end

  describe '#advance_to_resolution!' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'changes status to resolving' do
      fight.advance_to_resolution!
      expect(fight.reload.status).to eq('resolving')
    end

    it 'updates last_action_at' do
      old_time = fight.last_action_at
      sleep 0.01
      fight.advance_to_resolution!
      expect(fight.reload.last_action_at).to be > old_time
    end
  end

  describe '#complete!' do
    let(:fight) { Fight.create(room_id: room.id) }

    before do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )
    end

    it 'changes status to complete' do
      fight.complete!
      expect(fight.reload.status).to eq('complete')
    end

    it 'marks remaining participants as knocked out' do
      fight.complete!
      expect(fight.fight_participants.first.reload.is_knocked_out).to be true
    end

    it 'notifies Auto-GM session service when this fight is tracked as current_fight_id' do
      auto_session = instance_double(AutoGmSession)
      allow(AutoGmSession).to receive(:where).with(current_fight_id: fight.id, status: 'combat')
                                      .and_return(double(first: auto_session))
      allow(AutoGm::AutoGmSessionService).to receive(:process_combat_complete)

      fight.complete!

      expect(AutoGm::AutoGmSessionService).to have_received(:process_combat_complete)
        .with(auto_session, fight, :victory)
    end
  end

  describe '#winner' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'returns nil for incomplete fight' do
      expect(fight.winner).to be_nil
    end

    it 'returns the surviving participant after complete! marks everyone knocked out' do
      winner = FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )

      other_user = create(:user)
      other_char = Character.create(forename: 'Other', surname: 'Fighter', user: other_user, is_npc: false)
      other_instance = CharacterInstance.create(
        character: other_char,
        reality: reality,
        current_room: room,
        online: true
      )
      FightParticipant.create(
        fight: fight,
        character_instance: other_instance,
        current_hp: 0,
        max_hp: 6,
        side: 2,
        is_knocked_out: true
      )

      fight.complete!
      expect(fight.winner&.id).to eq(winner.id)
    end

    it 'returns nil when multiple participants still have HP remaining' do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )

      user2 = create(:user)
      char2 = Character.create(forename: 'Ally', surname: 'Two', user: user2, is_npc: false)
      ci2 = CharacterInstance.create(character: char2, reality: reality, current_room: room, online: true)
      FightParticipant.create(
        fight: fight,
        character_instance: ci2,
        current_hp: 4,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )

      fight.complete!
      expect(fight.winner).to be_nil
    end
  end

  describe '#round_locked?' do
    let(:fight) { Fight.create(room_id: room.id) }

    it 'returns false when round is not locked' do
      expect(fight.round_locked?).to be false
    end

    it 'returns true when round is locked' do
      fight.lock_round!
      expect(fight.round_locked?).to be true
    end
  end

  describe '.participant_in_active_fight?' do
    let(:fight) { Fight.create(room_id: room.id) }

    before do
      FightParticipant.create(
        fight: fight,
        character_instance: character_instance,
        current_hp: 6,
        max_hp: 6,
        side: 1,
        is_knocked_out: false
      )
    end

    it 'returns true for participant in active fight' do
      expect(described_class.participant_in_active_fight?(character_instance.id)).to be true
    end

    it 'returns false for participant not in any fight' do
      user2 = create(:user)
      char2 = Character.create(forename: 'Fighter', surname: 'Two', user: user2, is_npc: false)
      instance2 = CharacterInstance.create(
        character: char2,
        reality: reality,
        current_room: room,
        online: true,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )

      expect(described_class.participant_in_active_fight?(instance2.id)).to be false
    end

    it 'returns false for knocked out participant' do
      fight.fight_participants.first.update(is_knocked_out: true)
      expect(described_class.participant_in_active_fight?(character_instance.id)).to be false
    end
  end

  describe '#uses_new_hex_system?' do
    it 'returns false for fights created before migration' do
      fight = Fight.create(
        room_id: room.id,
        created_at: Time.new(2026, 2, 15, 0, 0, 0)
      )
      expect(fight.uses_new_hex_system?).to be false
    end

    it 'returns true for fights created after migration' do
      fight = Fight.create(
        room_id: room.id,
        created_at: Time.new(2026, 2, 17, 0, 0, 0)
      )
      expect(fight.uses_new_hex_system?).to be true
    end
  end

  describe 'battle map generation status' do
    let(:room) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
    let(:fight) { create(:fight, room: room) }

    describe '#awaiting_battle_map?' do
      it 'returns false when battle_map_generating is false' do
        fight.update(battle_map_generating: false)
        expect(fight.awaiting_battle_map?).to be false
      end

      it 'returns true when battle_map_generating is true' do
        fight.update(battle_map_generating: true)
        expect(fight.awaiting_battle_map?).to be true
      end
    end

    describe '#can_accept_combat_input?' do
      before { fight.update(status: 'input') }

      it 'returns true when accepting input and not generating' do
        fight.update(battle_map_generating: false)
        expect(fight.can_accept_combat_input?).to be true
      end

      it 'returns false when generating battle map' do
        fight.update(battle_map_generating: true)
        expect(fight.can_accept_combat_input?).to be false
      end

      it 'returns false when not in input status' do
        fight.update(status: 'resolving', battle_map_generating: false)
        expect(fight.can_accept_combat_input?).to be false
      end
    end

    describe '#start_battle_map_generation!' do
      it 'sets battle_map_generating to true' do
        fight.start_battle_map_generation!
        expect(fight.reload.battle_map_generating).to be true
      end
    end

    describe '#complete_battle_map_generation!' do
      it 'sets battle_map_generating to false' do
        fight.update(battle_map_generating: true)
        fight.complete_battle_map_generation!
        expect(fight.reload.battle_map_generating).to be false
      end
    end
  end
end
