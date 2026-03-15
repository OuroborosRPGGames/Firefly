# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveActionService do
  # Create mock participant and related objects
  let(:delve) { instance_double('Delve', name: 'Test Dungeon', difficulty: 'normal', time_limit_minutes: 30) }
  let(:room) { instance_double('DelveRoom', has_monster?: true, monster_type: 'Goblin', level: 1, clear_monster!: true) }
  let(:character_instance) { instance_double('CharacterInstance', in_combat?: false) }
  let(:participant) do
    instance_double('DelveParticipant',
                    delve: delve,
                    current_room: room,
                    character_instance: character_instance,
                    extracted?: false,
                    dead?: false,
                    active?: true,
                    time_expired?: false,
                    current_hp: 6,
                    max_hp: 6,
                    full_health?: true,
                    willpower_dice: 0,
                    studied_monsters: [],
                    loot_collected: 0,
                    rooms_explored: 5,
                    monsters_killed: 2,
                    total_damage: 5,
                    current_level: 1,
                    time_remaining: 20,
                    time_remaining_seconds: 1200,
                    status: 'active',
                    time_spent_minutes: 10,
                    time_spent_seconds: 600)
  end

  describe 'class methods' do
    it 'responds to fight!' do
      expect(described_class).to respond_to(:fight!)
    end

    it 'responds to flee!' do
      expect(described_class).to respond_to(:flee!)
    end

    it 'responds to status' do
      expect(described_class).to respond_to(:status)
    end

    it 'responds to recover!' do
      expect(described_class).to respond_to(:recover!)
    end

    it 'responds to focus!' do
      expect(described_class).to respond_to(:focus!)
    end

    it 'responds to study!' do
      expect(described_class).to respond_to(:study!)
    end

    it 'responds to handle_defeat!' do
      expect(described_class).to respond_to(:handle_defeat!)
    end

    it 'responds to handle_timeout!' do
      expect(described_class).to respond_to(:handle_timeout!)
    end
  end

  describe '.fight!' do
    before do
      allow(participant).to receive(:spend_time_seconds!).and_return(:ok)
      allow(participant).to receive(:take_hp_damage!)
      allow(participant).to receive(:take_damage!)
      allow(participant).to receive(:add_kill!)
      allow(participant).to receive(:add_loot!)
      allow(participant).to receive(:study_bonus_for).and_return(0)
      allow(delve).to receive(:monsters_in_room).and_return([])
    end

    it 'returns error if participant has no current room' do
      allow(participant).to receive(:current_room).and_return(nil)
      result = described_class.fight!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include("not in a delve")
    end

    it 'returns error if participant has extracted' do
      allow(participant).to receive(:extracted?).and_return(true)
      result = described_class.fight!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include("already extracted")
    end

    it 'returns error if time has expired' do
      allow(participant).to receive(:time_expired?).and_return(true)
      result = described_class.fight!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include("Time has run out")
    end

    it 'returns error if no monster in room' do
      allow(room).to receive(:has_monster?).and_return(false)
      result = described_class.fight!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include("nothing to fight")
    end

    it 'returns time expired result if combat runs out time' do
      allow(participant).to receive(:spend_time_seconds!).and_return(:time_expired)
      result = described_class.fight!(participant)
      expect(result[:success]).to be false
      expect(result[:data][:time_expired]).to be true
    end

    it 'spends full combat action time' do
      expected_seconds = Delve::ACTION_TIMES_SECONDS[:combat]
      expect(participant).to receive(:spend_time_seconds!).with(expected_seconds).and_return(:ok)

      described_class.fight!(participant)
    end

    it 'returns success with combat results' do
      allow(participant).to receive(:total_damage).and_return(10)
      allow(participant).to receive(:monsters_killed).and_return(3)
      allow(participant).to receive(:loot_collected).and_return(50)
      allow(participant).to receive(:time_remaining).and_return(15)
      allow(participant).to receive(:time_remaining_seconds).and_return(900)

      result = described_class.fight!(participant)
      expect(result[:success]).to be true
      expect(result[:message]).to include('defeat')
      expect(result[:data]).to include(:monster, :damage_taken, :kills, :bonus_loot)
    end

    it 'returns defeat and does not award victory when combat damage is lethal' do
      active_state = true
      allow(participant).to receive(:active?) { active_state }
      allow(participant).to receive(:take_hp_damage!) { active_state = false }
      allow(participant).to receive(:status).and_return('dead')
      allow(participant).to receive(:loot_collected).and_return(25)
      expect(participant).not_to receive(:add_kill!)
      expect(participant).not_to receive(:add_loot!)
      expect(room).not_to receive(:clear_monster!)

      result = described_class.fight!(participant)

      expect(result[:success]).to be false
      expect(result[:message]).to include('overwhelms you')
      expect(result[:data][:defeated]).to be true
    end
  end

  describe '.flee!' do
    let(:character_inst) { instance_double('CharacterInstance') }
    let(:safe_room) { instance_double('Room', id: 42, temporary?: false) }

    before do
      allow(participant).to receive(:extract!)
      allow(participant).to receive(:loot_collected).and_return(100)
      allow(participant).to receive(:rooms_explored).and_return(5)
      allow(participant).to receive(:monsters_killed).and_return(2)
      allow(participant).to receive(:total_damage).and_return(10)
      allow(participant).to receive(:current_level).and_return(2)
      allow(participant).to receive(:time_spent_minutes).and_return(15)
      allow(participant).to receive(:time_spent_seconds).and_return(900)
      allow(participant).to receive(:pre_delve_room_id).and_return(nil)
      allow(participant).to receive(:character_instance).and_return(character_inst)
      allow(character_inst).to receive(:safe_fallback_room).and_return(safe_room)
      allow(character_inst).to receive(:update)
      allow(FightService).to receive(:find_active_fight).with(character_inst).and_return(nil)
      allow(delve).to receive(:active_participants).and_return([])
      allow(TemporaryRoomPoolService).to receive(:release_delve_rooms)
        .and_return(double('Result', success?: true, :[] => 0))
    end

    it 'returns error if participant has no delve' do
      allow(participant).to receive(:delve).and_return(nil)
      result = described_class.flee!(participant)
      expect(result[:success]).to be false
    end

    it 'returns error if already extracted' do
      allow(participant).to receive(:extracted?).and_return(true)
      result = described_class.flee!(participant)
      expect(result[:success]).to be false
    end

    it 'returns error if participant is no longer active' do
      allow(participant).to receive(:active?).and_return(false)
      result = described_class.flee!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include('no longer flee')
    end

    it 'returns success with summary' do
      result = described_class.flee!(participant)
      expect(result[:success]).to be true
      expect(result[:message]).to include('flee')
      expect(result[:data]).to include(:loot, :rooms_explored, :monsters_killed)
    end

    it 'returns character to pre-delve room when it is not temporary' do
      pre_room = instance_double('Room', id: 42, temporary?: false)
      allow(participant).to receive(:pre_delve_room_id).and_return(42)
      allow(Room).to receive(:[]).with(42).and_return(pre_room)
      expect(character_inst).to receive(:update).with(current_room_id: 42)

      described_class.flee!(participant)
    end

    it 'falls back to safe room when pre_delve_room is temporary' do
      temp_room = instance_double('Room', id: 99, temporary?: true)
      allow(participant).to receive(:pre_delve_room_id).and_return(99)
      allow(Room).to receive(:[]).with(99).and_return(temp_room)
      expect(character_inst).to receive(:update).with(current_room_id: safe_room.id)

      described_class.flee!(participant)
    end

    it 'falls back to safe room when pre_delve_room_id is nil' do
      allow(participant).to receive(:pre_delve_room_id).and_return(nil)
      expect(character_inst).to receive(:update).with(current_room_id: safe_room.id)

      described_class.flee!(participant)
    end

    it 'releases delve rooms back to pool when no active participants remain' do
      expect(TemporaryRoomPoolService).to receive(:release_delve_rooms).with(delve)

      described_class.flee!(participant)
    end

    it 'does not release delve rooms while other participants are still active' do
      allow(delve).to receive(:active_participants).and_return([double('DelveParticipant')])
      expect(TemporaryRoomPoolService).not_to receive(:release_delve_rooms)

      described_class.flee!(participant)
    end

    it 'completes any active fight before extracting' do
      active_fight = instance_double('Fight')
      allow(FightService).to receive(:find_active_fight).with(character_inst).and_return(active_fight)
      expect(active_fight).to receive(:complete!)

      described_class.flee!(participant)
    end
  end

  describe '.status' do
    it 'returns error if participant has no delve' do
      allow(participant).to receive(:delve).and_return(nil)
      result = described_class.status(participant)
      expect(result[:success]).to be false
    end

    it 'returns status information' do
      result = described_class.status(participant)
      expect(result[:success]).to be true
      expect(result[:data]).to include(
        :delve_name,
        :difficulty,
        :current_level,
        :time_remaining,
        :loot_collected
      )
    end

    it 'includes character stats in message' do
      result = described_class.status(participant)
      expect(result[:message]).to include('HP')
      expect(result[:message]).to include('Loot')
      expect(result[:message]).to include('Kills')
    end
  end

  describe '.recover!' do
    before do
      allow(participant).to receive(:spend_time_seconds!).and_return(:ok)
      allow(participant).to receive(:heal!)
      allow(participant).to receive(:full_health?).and_return(false)
      allow(participant).to receive(:current_hp).and_return(6)
      allow(participant).to receive(:max_hp).and_return(6)
      allow(participant).to receive(:time_remaining).and_return(15)
      allow(participant).to receive(:time_remaining_seconds).and_return(900)
    end

    it 'returns error if already at full health' do
      allow(participant).to receive(:full_health?).and_return(true)
      result = described_class.recover!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include('full health')
    end

    it 'returns success and heals' do
      result = described_class.recover!(participant)
      expect(result[:success]).to be true
      expect(participant).to have_received(:heal!)
    end
  end

  describe '.focus!' do
    before do
      allow(participant).to receive(:spend_time_seconds!).and_return(:ok)
      allow(participant).to receive(:add_willpower!)
      allow(participant).to receive(:willpower_dice).and_return(1)
      allow(participant).to receive(:time_remaining).and_return(15)
      allow(participant).to receive(:time_remaining_seconds).and_return(900)
    end

    it 'adds willpower die' do
      result = described_class.focus!(participant)
      expect(result[:success]).to be true
      expect(participant).to have_received(:add_willpower!)
    end
  end

  describe '.study!' do
    before do
      allow(participant).to receive(:spend_time_seconds!).and_return(:ok)
      allow(participant).to receive(:has_studied?).and_return(false)
      allow(participant).to receive(:add_study!)
      allow(participant).to receive(:studied_monsters).and_return(['Goblin'])
      allow(participant).to receive(:time_remaining).and_return(15)
      allow(participant).to receive(:time_remaining_seconds).and_return(900)
    end

    it 'returns error if already studied that monster' do
      allow(participant).to receive(:has_studied?).with('Goblin').and_return(true)
      result = described_class.study!(participant, 'Goblin')
      expect(result[:success]).to be false
      expect(result[:message]).to include('already studied')
    end

    it 'adds study of monster type' do
      result = described_class.study!(participant, 'Goblin')
      expect(result[:success]).to be true
      expect(participant).to have_received(:add_study!).with('Goblin')
    end
  end

  describe '.handle_defeat!' do
    before do
      allow(participant).to receive(:handle_defeat!).and_return(50)
      allow(participant).to receive(:loot_collected).and_return(50)
    end

    it 'returns defeat result with loot lost' do
      result = described_class.handle_defeat!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include('defeated')
      expect(result[:data][:loot_lost]).to eq(50)
    end
  end

  describe '.handle_timeout!' do
    before do
      allow(participant).to receive(:handle_timeout!).and_return(25)
      allow(participant).to receive(:loot_collected).and_return(75)
    end

    it 'returns timeout result with loot lost' do
      result = described_class.handle_timeout!(participant)
      expect(result[:success]).to be false
      expect(result[:message]).to include('Time has run out')
      expect(result[:data][:loot_lost]).to eq(25)
    end
  end
end
