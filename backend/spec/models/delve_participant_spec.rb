# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveParticipant do
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end
  let(:delve) { create(:delve) }

  describe 'validations' do
    it 'requires delve_id' do
      participant = DelveParticipant.new(character_instance_id: character_instance.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:delve_id]).not_to be_empty
    end

    it 'requires character_instance_id' do
      participant = DelveParticipant.new(delve_id: delve.id)
      expect(participant.valid?).to be false
      expect(participant.errors[:character_instance_id]).not_to be_empty
    end

    it 'validates uniqueness of character per delve' do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
      duplicate = DelveParticipant.new(delve_id: delve.id, character_instance_id: character_instance.id)
      expect(duplicate.valid?).to be false
    end

    it 'validates status is in allowed list' do
      participant = DelveParticipant.new(
        delve_id: delve.id,
        character_instance_id: character_instance.id,
        status: 'invalid'
      )
      expect(participant.valid?).to be false
    end
  end

  describe 'defaults' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    it 'sets default status to active' do
      expect(participant.status).to eq('active')
    end

    it 'sets default loot_collected to 0' do
      expect(participant.loot_collected).to eq(0)
    end

    it 'sets default rooms_explored to 0' do
      expect(participant.rooms_explored).to eq(0)
    end

    it 'sets default willpower_dice to 0' do
      expect(participant.willpower_dice).to eq(0)
    end

    it 'sets default current_hp to max_hp' do
      expect(participant.current_hp).to eq(participant.max_hp)
    end

    it 'initializes studied_monsters as empty array' do
      expect(participant.studied_monsters).to eq([])
    end
  end

  describe 'status methods' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    describe '#active?' do
      it 'returns true when status is active' do
        expect(participant.active?).to be true
      end

      it 'returns false when status is not active' do
        participant.update(status: 'extracted')
        expect(participant.active?).to be false
      end
    end

    describe '#extracted?' do
      it 'returns true when status is extracted' do
        participant.update(status: 'extracted')
        expect(participant.extracted?).to be true
      end
    end

    describe '#dead?' do
      it 'returns true when status is dead' do
        participant.update(status: 'dead')
        expect(participant.dead?).to be true
      end
    end

    describe '#extract!' do
      it 'sets status to extracted' do
        participant.extract!
        expect(participant.extracted?).to be true
      end

      it 'sets extracted_at timestamp' do
        participant.extract!
        expect(participant.extracted_at).not_to be_nil
      end
    end

    describe '#die!' do
      it 'sets status to dead' do
        participant.die!
        expect(participant.dead?).to be true
      end
    end

    describe '#flee!' do
      it 'sets status to fled' do
        participant.flee!
        expect(participant.status).to eq('fled')
      end
    end
  end

  describe 'loot and exploration' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    describe '#add_loot!' do
      it 'increases loot_collected' do
        participant.add_loot!(100)
        expect(participant.loot_collected).to eq(100)
      end

      it 'accumulates loot' do
        participant.add_loot!(50)
        participant.add_loot!(30)
        expect(participant.loot_collected).to eq(80)
      end
    end

    describe '#explore_room!' do
      it 'increments rooms_explored' do
        participant.explore_room!
        expect(participant.rooms_explored).to eq(1)
      end
    end
  end

  describe 'HP management' do
    let(:participant) do
      DelveParticipant.create(
        delve_id: delve.id,
        character_instance_id: character_instance.id,
        current_hp: 6,
        max_hp: 6
      )
    end

    describe '#take_hp_damage!' do
      it 'reduces current_hp' do
        participant.take_hp_damage!(2)
        expect(participant.current_hp).to eq(4)
      end

      it 'tracks damage_taken' do
        participant.take_hp_damage!(3)
        expect(participant.damage_taken).to eq(3)
      end

      it 'sets status to dead when HP reaches 0' do
        participant.take_hp_damage!(6)
        expect(participant.dead?).to be true
      end

      it 'does not go below 0 HP' do
        participant.take_hp_damage!(10)
        expect(participant.current_hp).to eq(0)
      end
    end

    describe '#heal!' do
      before { participant.take_hp_damage!(4) }

      it 'heals specified amount' do
        participant.heal!(2)
        expect(participant.current_hp).to eq(4)
      end

      it 'does not exceed max_hp' do
        participant.heal!(10)
        expect(participant.current_hp).to eq(6)
      end

      it 'full heals when no amount specified' do
        participant.heal!
        expect(participant.current_hp).to eq(6)
      end
    end

    describe '#defeated?' do
      it 'returns true when HP is 0' do
        participant.character_instance.update(health: 0)
        expect(participant.defeated?).to be true
      end

      it 'returns false when HP is positive' do
        expect(participant.defeated?).to be false
      end
    end

    describe '#full_health?' do
      it 'returns true at full HP' do
        expect(participant.full_health?).to be true
      end

      it 'returns false when damaged' do
        participant.take_hp_damage!(1)
        expect(participant.full_health?).to be false
      end
    end
  end

  describe 'willpower' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    describe '#add_willpower!' do
      it 'adds willpower dice' do
        participant.add_willpower!(2)
        expect(participant.willpower_dice).to eq(2)
      end

      it 'defaults to adding 1' do
        participant.add_willpower!
        expect(participant.willpower_dice).to eq(1)
      end
    end

    describe '#use_willpower!' do
      before { participant.update(willpower_dice: 2) }

      it 'decrements willpower dice' do
        participant.use_willpower!
        expect(participant.willpower_dice).to eq(1)
      end

      it 'returns true when successful' do
        expect(participant.use_willpower!).to be true
      end

      it 'returns false when no willpower available' do
        participant.update(willpower_dice: 0)
        expect(participant.use_willpower!).to be false
      end
    end
  end

  describe 'study system' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    describe '#add_study!' do
      it 'adds monster type to studied list' do
        participant.add_study!('goblin')
        expect(participant.studied_monsters).to include('goblin')
      end

      it 'does not add duplicates' do
        participant.add_study!('goblin')
        participant.add_study!('goblin')
        expect(participant.studied_monsters.count { |m| m == 'goblin' }).to eq(1)
      end
    end

    describe '#has_studied?' do
      it 'returns true for studied monsters' do
        participant.add_study!('goblin')
        expect(participant.has_studied?('goblin')).to be true
      end

      it 'returns false for unstudied monsters' do
        expect(participant.has_studied?('dragon')).to be false
      end
    end

    describe '#study_bonus_for' do
      it 'returns 2 for studied monsters' do
        participant.add_study!('goblin')
        expect(participant.study_bonus_for('goblin')).to eq(2)
      end

      it 'returns 0 for unstudied monsters' do
        expect(participant.study_bonus_for('dragon')).to eq(0)
      end
    end
  end

  describe 'combat tracking' do
    let(:participant) do
      DelveParticipant.create(delve_id: delve.id, character_instance_id: character_instance.id)
    end

    describe '#add_kill!' do
      it 'increments monsters_killed' do
        participant.add_kill!
        participant.add_kill!
        expect(participant.monsters_killed).to eq(2)
      end
    end

    describe '#add_trap_trigger!' do
      it 'increments traps_triggered' do
        participant.add_trap_trigger!
        expect(participant.traps_triggered).to eq(1)
      end
    end
  end

  describe 'time management' do
    let(:participant) do
      DelveParticipant.create(
        delve_id: delve.id,
        character_instance_id: character_instance.id,
        loot_collected: 100,
        time_spent_seconds: 59
      )
    end

    before do
      delve.update(time_limit_minutes: 1)
      allow(GameSetting).to receive(:get).and_call_original
      allow(GameSetting).to receive(:get).with('delve_defeat_loot_penalty').and_return('0.5')
      allow(character_instance).to receive(:safe_fallback_room).and_return(room)
    end

    describe '#spend_time_seconds!' do
      it 'returns :time_expired and applies timeout handling when time runs out' do
        result = participant.spend_time_seconds!(2)

        expect(result).to eq(:time_expired)
        expect(participant.reload.status).to eq('fled')
        expect(participant.loot_collected).to eq(50)
      end
    end

    describe '#handle_timeout!' do
      it 'is idempotent after the first timeout application' do
        first_loss = participant.handle_timeout!
        second_loss = participant.handle_timeout!

        expect(first_loss).to eq(50)
        expect(second_loss).to eq(0)
        expect(participant.reload.loot_collected).to eq(50)
        expect(participant.status).to eq('fled')
      end

      it 'returns character to pre-delve room and releases delve rooms when last active participant' do
        delve_room = create(:room, location: location)
        character_instance.update(current_room_id: delve_room.id)
        participant.update(pre_delve_room_id: room.id)
        allow(TemporaryRoomPoolService).to receive(:release_delve_rooms)

        participant.handle_timeout!

        expect(character_instance.reload.current_room_id).to eq(room.id)
        expect(TemporaryRoomPoolService).to have_received(:release_delve_rooms).with(delve)
      end

      it 'does not release delve rooms while other active participants remain' do
        other_character = create(:character, user: user, forename: 'Bob')
        other_instance = create(:character_instance, character: other_character, current_room: room, reality: reality, online: true)
        DelveParticipant.create(delve_id: delve.id, character_instance_id: other_instance.id, status: 'active')
        allow(TemporaryRoomPoolService).to receive(:release_delve_rooms)

        participant.handle_timeout!

        expect(TemporaryRoomPoolService).not_to have_received(:release_delve_rooms)
      end
    end

    describe '#handle_defeat!' do
      it 'is idempotent after the first defeat application' do
        first_loss = participant.handle_defeat!
        second_loss = participant.handle_defeat!

        expect(first_loss).to eq(50)
        expect(second_loss).to eq(0)
        expect(participant.reload.loot_collected).to eq(50)
        expect(participant.status).to eq('dead')
      end
    end
  end

  describe 'constants' do
    it 'defines valid statuses' do
      expect(DelveParticipant::STATUSES).to include('active', 'extracted', 'dead', 'fled')
    end
  end
end
