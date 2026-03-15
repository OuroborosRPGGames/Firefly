# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveCombatService do
  # CombatAIService is called when creating NPC fight participants;
  # stub globally so test doubles don't need full Fight graph.
  let(:combat_ai_double) { double('CombatAIService', apply_decisions!: true) }
  let(:primary_reality) { double('Reality', id: 1, reality_type: 'primary') }

  before do
    allow(CombatAIService).to receive(:new).and_return(combat_ai_double)
    # Stub Reality lookup used by monster archetype linking
    allow(Reality).to receive(:first).with(reality_type: 'primary').and_return(primary_reality)
    # Default: no template character found (bare NPC fallback)
    allow(Character).to receive(:first).and_return(nil)
  end

  describe 'constants' do
    it 'defines COMBAT_ROUND_TIME_SECONDS' do
      expect(described_class::COMBAT_ROUND_TIME_SECONDS).to eq(10)
    end
  end

  describe 'Result struct' do
    it 'defines Result struct with success, message, data' do
      result = described_class::Result.new(success: true, message: 'test', data: {})
      expect(result.success).to be true
      expect(result.message).to eq('test')
      expect(result.data).to eq({})
    end
  end

  describe '.create_fight!' do
    let(:room_for_fight) { double('Room', id: 123) }
    let(:rooms_dataset) { double('Dataset', first: room_for_fight) }
    let(:location) { double('Location', rooms_dataset: rooms_dataset) }
    let(:delve) { double('Delve', id: 1, location: location) }
    let(:monster) do
      double('DelveMonster',
        id: 456,
        display_name: 'Goblin',
        max_hp: 10,
        hp: 10,
        damage_bonus: 2,
        monster_type: 'goblin',
        difficulty_text: 'Normal',
        current_room: double('Room', id: 123)
      )
    end
    let(:character_instance) { double('CharacterInstance', id: 1) }
    let(:participant) do
      double('DelveParticipant',
        character_instance: character_instance,
        max_hp: 6,
        current_hp: 6,
        willpower_dice: 1.0,
        study_bonus_for: 1
      )
    end
    let(:fight) { double('Fight', id: 1, update: true) }

    before do
      allow(Fight).to receive(:create).and_return(fight)
      allow(FightParticipant).to receive(:create)
      allow(monster).to receive(:respond_to?).with(:fight_id=).and_return(false)
    end

    it 'creates a fight record' do
      expect(Fight).to receive(:create).with(hash_including(
        room_id: 123,
        has_monster: true
      )).and_return(fight)

      described_class.create_fight!(delve, monster, [participant])
    end

    it 'adds monster as NPC participant' do
      expect(FightParticipant).to receive(:create).with(hash_including(
        fight_id: 1,
        is_npc: true,
        npc_name: 'Goblin',
        max_hp: 10,
        current_hp: 10,
        npc_damage_bonus: 2,
        side: 2
      ))

      described_class.create_fight!(delve, monster, [participant])
    end

    it 'adds PC participants' do
      expect(FightParticipant).to receive(:create).with(hash_including(
        fight_id: 1,
        character_instance_id: 1,
        max_hp: 6,
        current_hp: 6,
        side: 1
      ))

      # Also allow the monster participant creation
      allow(FightParticipant).to receive(:create).with(hash_including(is_npc: true))

      described_class.create_fight!(delve, monster, [participant])
    end

    it 'delegates to create_fight_with_multiple_monsters!' do
      expect(described_class).to receive(:create_fight_with_multiple_monsters!)
        .with(delve, [monster], [participant], delve_room: nil)
        .and_call_original

      described_class.create_fight!(delve, monster, [participant])
    end

    it 'returns fight info hash' do
      result = described_class.create_fight!(delve, monster, [participant])

      expect(result[:fight_started]).to be true
      expect(result[:fight_id]).to eq(1)
      expect(result[:monster_names]).to contain_exactly('Goblin')
      expect(result[:monster_count]).to eq(1)
    end
  end

  describe '.process_round_time!' do
    let(:delve) { double('Delve') }
    let(:participant1) do
      double('DelveParticipant',
        time_expired?: false
      )
    end
    let(:participant2) do
      double('DelveParticipant',
        time_expired?: true,
        handle_timeout!: 50
      )
    end

    before do
      allow(participant1).to receive(:spend_time_seconds!)
      allow(participant2).to receive(:spend_time_seconds!)
      allow(GameSetting).to receive(:get_integer).with('delve_time_combat_round').and_return(10)
      allow(DelveMonsterService).to receive(:tick_movement!).and_return([])
    end

    it 'spends time for each participant' do
      expect(participant1).to receive(:spend_time_seconds!).with(10)
      expect(participant2).to receive(:spend_time_seconds!).with(10)

      described_class.process_round_time!(delve, [participant1, participant2])
    end

    it 'handles timeout for expired participants' do
      expect(participant2).to receive(:handle_timeout!).and_return(50)

      events = described_class.process_round_time!(delve, [participant1, participant2])

      timeout_event = events.find { |e| e[:type] == :timeout }
      expect(timeout_event).not_to be_nil
      expect(timeout_event[:participant]).to eq(participant2)
      expect(timeout_event[:loot_lost]).to eq(50)
    end

    it 'uses loot delta when spend_time_seconds! already handled timeout penalty' do
      allow(participant2).to receive(:spend_time_seconds!).and_return(:time_expired)
      allow(participant2).to receive(:loot_collected).and_return(100, 50)
      expect(participant2).not_to receive(:handle_timeout!)

      events = described_class.process_round_time!(delve, [participant2])
      timeout_event = events.find { |e| e[:type] == :timeout }

      expect(timeout_event).not_to be_nil
      expect(timeout_event[:loot_lost]).to eq(50)
    end

    it 'ticks monster movement' do
      expect(DelveMonsterService).to receive(:tick_movement!).with(delve, 10).and_return([])

      described_class.process_round_time!(delve, [participant1])
    end

    it 'includes reinforcement events from monster movement' do
      collision = { monster: double('Monster'), room: double('Room') }
      allow(DelveMonsterService).to receive(:tick_movement!).and_return([collision])

      events = described_class.process_round_time!(delve, [participant1])

      reinforcement_event = events.find { |e| e[:type] == :reinforcement }
      expect(reinforcement_event).not_to be_nil
    end

    it 'uses default time when setting is not configured' do
      allow(GameSetting).to receive(:get_integer).with('delve_time_combat_round').and_return(nil)

      expect(participant1).to receive(:spend_time_seconds!).with(10)

      described_class.process_round_time!(delve, [participant1])
    end
  end

  describe '.handle_fight_end!' do
    let(:delve) { double('Delve', id: 1) }
    let(:monster) { double('DelveMonster', display_name: 'Goblin', difficulty_value: 20, current_room_id: nil) }
    let(:participant) do
      double('DelveParticipant',
        character_instance_id: 1,
        add_loot!: nil,
        add_kill!: nil
      )
    end
    let(:fight) { double('Fight', id: 1) }
    let(:pc_participant) { double('FightParticipant', is_npc: false, current_hp: 5) }
    let(:npc_participant) { double('FightParticipant', is_npc: true, current_hp: 0) }
    let(:monster_dataset) { double('Dataset') }

    before do
      allow(fight).to receive(:fight_participants).and_return([pc_participant, npc_participant])
      allow(DelveMonster).to receive(:where).and_return(monster_dataset)
      allow(monster_dataset).to receive(:all).and_return([monster])
      allow(monster).to receive(:deactivate!)
    end

    context 'when PCs win' do
      it 'deactivates all monsters linked to the fight' do
        expect(monster).to receive(:deactivate!)

        described_class.handle_fight_end!(fight, delve, [participant])
      end

      it 'awards loot bonus to participants' do
        expect(participant).to receive(:add_loot!).with(10) # difficulty_value / 2

        described_class.handle_fight_end!(fight, delve, [participant])
      end

      it 'increments kill count' do
        expect(participant).to receive(:add_kill!)

        described_class.handle_fight_end!(fight, delve, [participant])
      end

      it 'returns victory result' do
        result = described_class.handle_fight_end!(fight, delve, [participant])

        expect(result.success).to be true
        expect(result.data[:victory]).to be true
        expect(result.data[:loot_bonus]).to eq(10)
        expect(result.message).to include('slain!')
      end
    end

    context 'when PCs lose' do
      let(:defeated_pc) { double('FightParticipant', is_npc: false, current_hp: 0) }
      let(:char_instance) { double('CharacterInstance') }
      let(:pre_delve_room) { double('Room', id: 99, temporary?: false) }
      let(:safe_room) { double('Room', id: 42, temporary?: false) }

      before do
        allow(fight).to receive(:fight_participants).and_return([defeated_pc, npc_participant])
        allow(participant).to receive(:handle_defeat!).and_return(25)
        allow(participant).to receive(:pre_delve_room_id).and_return(99)
        allow(participant).to receive(:character_instance).and_return(char_instance)
        allow(char_instance).to receive(:update)
        allow(char_instance).to receive(:safe_fallback_room).and_return(safe_room)
        allow(Room).to receive(:[]).with(99).and_return(pre_delve_room)
        allow(TemporaryRoomPoolService).to receive(:release_delve_rooms)
      end

      it 'handles defeat for participants and restores position' do
        expect(participant).to receive(:handle_defeat!).and_return(25)
        expect(char_instance).to receive(:update).with(current_room_id: 99)
        expect(TemporaryRoomPoolService).to receive(:release_delve_rooms).with(delve)

        described_class.handle_fight_end!(fight, delve, [participant])
      end

      it 'falls back to safe room when pre_delve_room is temporary' do
        temp_room = double('Room', id: 99, temporary?: true)
        allow(Room).to receive(:[]).with(99).and_return(temp_room)
        expect(char_instance).to receive(:update).with(current_room_id: safe_room.id)

        described_class.handle_fight_end!(fight, delve, [participant])
      end

      it 'returns defeat result with loot lost' do
        result = described_class.handle_fight_end!(fight, delve, [participant])

        expect(result.success).to be true
        expect(result.data[:victory]).to be false
        expect(result.data[:loot_lost]).to eq(25)
        expect(result.data[:defeated]).to be true
        expect(result.message).to include('defeated')
      end
    end

    context 'when no monsters linked to fight' do
      before do
        allow(monster_dataset).to receive(:all).and_return([])
      end

      it 'awards default bonus when no monsters found' do
        expect(participant).to receive(:add_loot!).with(5)

        described_class.handle_fight_end!(fight, delve, [participant])
      end
    end
  end

  describe '.check_auto_combat!' do
    let(:room_for_fight) { double('Room', id: 999, battle_map_ready?: false) }
    let(:rooms_dataset) { double('RoomsDataset', first: room_for_fight) }
    let(:location) { double('Location', rooms_dataset: rooms_dataset) }
    let(:delve) { double('Delve', id: 1, location: location) }
    let(:room) { double('DelveRoom', id: 123, room: nil) }
    let(:character_instance) { double('CharacterInstance', id: 1) }
    let(:participant) do
      double('DelveParticipant',
        character_instance: character_instance,
        character_instance_id: 1,
        max_hp: 6,
        current_hp: 6,
        willpower_dice: 1.0,
        study_bonus_for: 0,
        status: 'active',
        current_delve_room_id: 123
      )
    end
    let(:monster) do
      double('DelveMonster',
        id: 456,
        display_name: 'Goblin',
        max_hp: 10,
        hp: 10,
        damage_bonus: 2,
        monster_type: 'goblin',
        current_room: double('Room', id: 999),
        update: true,
        'respond_to?': ->(method) { method == :fight_id= }
      )
    end
    let(:participants_dataset) { double('Dataset') }

    context 'when monsters are in the room' do
      let(:fight) { double('Fight', id: 1, update: true) }

      before do
        allow(delve).to receive(:monsters_in_room).with(room).and_return([monster])
        allow(delve).to receive(:delve_participants_dataset).and_return(participants_dataset)
        allow(participants_dataset).to receive(:where).and_return(participants_dataset)
        allow(participants_dataset).to receive(:all).and_return([participant])
        allow(Fight).to receive(:create).and_return(fight)
        allow(FightParticipant).to receive(:create)
        allow(monster).to receive(:respond_to?).with(:fight_id=).and_return(true)
        allow(monster).to receive(:update)
      end

      it 'creates a fight with all monsters' do
        expect(Fight).to receive(:create).with(hash_including(
          room_id: 999,
          has_monster: true
        )).and_return(fight)

        result = described_class.check_auto_combat!(delve, participant, room)

        expect(result).not_to be_nil
        expect(result[:fight_started]).to be true
        expect(result[:fight_id]).to eq(1)
      end

      it 'adds all monsters as fight participants on side 2' do
        second_monster = double('DelveMonster',
          id: 789,
          display_name: 'Spider',
          max_hp: 8,
          hp: 8,
          damage_bonus: 1,
          monster_type: 'spider',
          current_room: double('Room', id: 999)
        )
        allow(second_monster).to receive(:respond_to?).with(:fight_id=).and_return(true)
        allow(second_monster).to receive(:update)
        allow(delve).to receive(:monsters_in_room).with(room).and_return([monster, second_monster])

        # Expect both monsters to be added as NPC participants
        expect(FightParticipant).to receive(:create).with(hash_including(
          is_npc: true,
          npc_name: 'Goblin',
          side: 2
        ))
        expect(FightParticipant).to receive(:create).with(hash_including(
          is_npc: true,
          npc_name: 'Spider',
          side: 2
        ))

        # PC participant
        expect(FightParticipant).to receive(:create).with(hash_including(
          character_instance_id: 1,
          side: 1
        ))

        result = described_class.check_auto_combat!(delve, participant, room)
        expect(result[:monster_count]).to eq(2)
      end

      it 'adds all active delve participants in the room' do
        other_ci = double('CharacterInstance', id: 2)
        other_participant = double('DelveParticipant',
          character_instance: other_ci,
          character_instance_id: 2,
          max_hp: 6,
          current_hp: 5,
          willpower_dice: 1.0,
          study_bonus_for: 0,
          status: 'active',
          current_delve_room_id: 123
        )
        allow(participants_dataset).to receive(:all).and_return([participant, other_participant])

        # Expect both PC participants on side 1
        expect(FightParticipant).to receive(:create).with(hash_including(
          character_instance_id: 1,
          side: 1
        ))
        expect(FightParticipant).to receive(:create).with(hash_including(
          character_instance_id: 2,
          side: 1
        ))

        # Monster on side 2
        expect(FightParticipant).to receive(:create).with(hash_including(
          is_npc: true,
          side: 2
        ))

        described_class.check_auto_combat!(delve, participant, room)
      end

      # Note: Study bonus is applied during roll calculation in FightService,
      # not stored on the FightParticipant. The DelveParticipant tracks what
      # monsters have been studied, and that bonus is used during combat rolls.

      it 'returns monster names and count' do
        second_monster = double('DelveMonster',
          id: 789,
          display_name: 'Spider',
          max_hp: 8,
          hp: 8,
          damage_bonus: 1,
          monster_type: 'spider',
          current_room: double('Room', id: 999)
        )
        allow(second_monster).to receive(:respond_to?).with(:fight_id=).and_return(true)
        allow(second_monster).to receive(:update)
        allow(delve).to receive(:monsters_in_room).with(room).and_return([monster, second_monster])

        result = described_class.check_auto_combat!(delve, participant, room)

        expect(result[:monster_names]).to contain_exactly('Goblin', 'Spider')
        expect(result[:monster_count]).to eq(2)
      end

      it 'links monsters to fight via fight_id' do
        second_monster = double('DelveMonster',
          id: 789,
          display_name: 'Spider',
          max_hp: 8,
          hp: 8,
          damage_bonus: 1,
          monster_type: 'spider',
          current_room: double('Room', id: 999)
        )
        allow(second_monster).to receive(:respond_to?).with(:fight_id=).and_return(true)
        allow(delve).to receive(:monsters_in_room).with(room).and_return([monster, second_monster])

        # Expect each monster to be updated with fight_id
        expect(monster).to receive(:update).with(fight_id: 1)
        expect(second_monster).to receive(:update).with(fight_id: 1)

        described_class.check_auto_combat!(delve, participant, room)
      end
    end

    context 'when no monsters in room' do
      before do
        allow(delve).to receive(:monsters_in_room).with(room).and_return([])
        allow(room).to receive(:has_monster?).and_return(false)
      end

      it 'returns nil' do
        result = described_class.check_auto_combat!(delve, participant, room)
        expect(result).to be_nil
      end

      it 'does not create a fight' do
        expect(Fight).not_to receive(:create)
        described_class.check_auto_combat!(delve, participant, room)
      end
    end
  end

  describe '.create_fight_with_multiple_monsters!' do
    let(:room_for_fight) { double('Room', id: 999) }
    let(:rooms_dataset) { double('Dataset', first: room_for_fight) }
    let(:location) { double('Location', rooms_dataset: rooms_dataset) }
    let(:delve) { double('Delve', id: 1, location: location) }
    let(:character_instance) { double('CharacterInstance', id: 1) }
    let(:participant) do
      double('DelveParticipant',
        character_instance: character_instance,
        max_hp: 6,
        current_hp: 6,
        willpower_dice: 1.0,
        study_bonus_for: 2
      )
    end
    let(:monster1) do
      double('DelveMonster',
        id: 100,
        display_name: 'Goblin',
        max_hp: 10,
        hp: 10,
        damage_bonus: 2,
        monster_type: 'goblin',
        current_room: double('Room', id: 999)
      )
    end
    let(:monster2) do
      double('DelveMonster',
        id: 101,
        display_name: 'Spider',
        max_hp: 8,
        hp: 8,
        damage_bonus: 1,
        monster_type: 'spider',
        current_room: nil
      )
    end
    let(:fight) { double('Fight', id: 42, update: true) }

    before do
      allow(Fight).to receive(:create).and_return(fight)
      allow(FightParticipant).to receive(:create)
    end

    it 'creates a fight record' do
      expect(Fight).to receive(:create).with(hash_including(
        room_id: 999,
        has_monster: true
      )).and_return(fight)

      described_class.create_fight_with_multiple_monsters!(delve, [monster1, monster2], [participant])
    end

    it 'adds each monster as NPC participant on side 2' do
      allow(monster1).to receive(:respond_to?).with(:fight_id=).and_return(false)
      allow(monster2).to receive(:respond_to?).with(:fight_id=).and_return(false)

      expect(FightParticipant).to receive(:create).with(hash_including(
        fight_id: 42,
        is_npc: true,
        npc_name: 'Goblin',
        max_hp: 10,
        current_hp: 10,
        npc_damage_bonus: 2,
        side: 2
      ))
      expect(FightParticipant).to receive(:create).with(hash_including(
        fight_id: 42,
        is_npc: true,
        npc_name: 'Spider',
        max_hp: 8,
        current_hp: 8,
        npc_damage_bonus: 1,
        side: 2
      ))

      # PC participant
      allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

      described_class.create_fight_with_multiple_monsters!(delve, [monster1, monster2], [participant])
    end

    it 'adds PC participants on side 1' do
      allow(monster1).to receive(:respond_to?).with(:fight_id=).and_return(false)
      allow(monster2).to receive(:respond_to?).with(:fight_id=).and_return(false)

      expect(FightParticipant).to receive(:create).with(hash_including(
        fight_id: 42,
        character_instance_id: 1,
        max_hp: 6,
        current_hp: 6,
        side: 1
      ))

      # Monster participants
      allow(FightParticipant).to receive(:create).with(hash_including(is_npc: true))

      described_class.create_fight_with_multiple_monsters!(delve, [monster1, monster2], [participant])
    end

    it 'returns fight info hash' do
      allow(monster1).to receive(:respond_to?).with(:fight_id=).and_return(false)
      allow(monster2).to receive(:respond_to?).with(:fight_id=).and_return(false)

      result = described_class.create_fight_with_multiple_monsters!(delve, [monster1, monster2], [participant])

      expect(result[:fight_started]).to be true
      expect(result[:fight_id]).to eq(42)
      expect(result[:monster_names]).to contain_exactly('Goblin', 'Spider')
      expect(result[:monster_count]).to eq(2)
    end
  end

  describe 'monster archetype linking' do
    let(:room_for_fight) { double('Room', id: 999) }
    let(:rooms_dataset) { double('Dataset', first: room_for_fight) }
    let(:location) { double('Location', rooms_dataset: rooms_dataset) }
    let(:delve) { double('Delve', id: 1, location: location) }
    let(:character_instance) { double('CharacterInstance', id: 1) }
    let(:participant) do
      double('DelveParticipant',
        character_instance: character_instance,
        max_hp: 6,
        current_hp: 6,
        willpower_dice: 1.0
      )
    end
    let(:monster) do
      double('DelveMonster',
        id: 456,
        display_name: 'Goblin',
        max_hp: 10,
        hp: 10,
        damage_bonus: 2,
        monster_type: 'goblin'
      )
    end
    let(:fight) { double('Fight', id: 42, update: true) }
    let(:template_char) { double('Character', id: 77, forename: 'Monster:goblin') }
    let(:monster_ci) { double('CharacterInstance', id: 200) }

    before do
      allow(Fight).to receive(:create).and_return(fight)
      allow(FightParticipant).to receive(:create)
      allow(monster).to receive(:respond_to?).with(:fight_id=).and_return(false)
    end

    context 'when template character exists' do
      before do
        allow(Character).to receive(:first).with(forename: 'Monster:goblin').and_return(template_char)
        allow(CharacterInstance).to receive(:create).and_return(monster_ci)
      end

      it 'creates a CharacterInstance for the monster' do
        expect(CharacterInstance).to receive(:create).with(hash_including(
          character_id: 77,
          reality_id: primary_reality.id,
          current_room_id: 999,
          online: false,
          status: 'alive'
        )).and_return(monster_ci)

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end

      it 'sets character_instance_id on the FightParticipant' do
        expect(FightParticipant).to receive(:create).with(hash_including(
          fight_id: 42,
          is_npc: true,
          npc_name: 'Goblin',
          character_instance_id: 200,
          side: 2
        ))

        # Allow PC participant creation
        allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end

      it 'does not set npc_damage_dice_count or npc_damage_dice_sides' do
        expect(FightParticipant).to receive(:create).with(
          satisfying { |attrs|
            attrs[:is_npc] == true &&
              !attrs.key?(:npc_damage_dice_count) &&
              !attrs.key?(:npc_damage_dice_sides)
          }
        )

        # Allow PC participant creation
        allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end

      it 'still sets npc_damage_bonus from monster.damage_bonus' do
        expect(FightParticipant).to receive(:create).with(hash_including(
          is_npc: true,
          npc_damage_bonus: 2
        ))

        allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end
    end

    context 'when template character is not found' do
      before do
        allow(Character).to receive(:first).with(forename: 'Monster:goblin').and_return(nil)
      end

      it 'creates bare NPC FightParticipant without character_instance_id' do
        expect(FightParticipant).to receive(:create).with(
          satisfying { |attrs|
            attrs[:is_npc] == true &&
              !attrs.key?(:character_instance_id) &&
              attrs[:npc_name] == 'Goblin'
          }
        )

        allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end

      it 'logs a warning' do
        expect { described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant]) }
          .to output(/No template character found for monster type 'goblin'/).to_stderr
      end
    end

    context 'when reality is not found' do
      before do
        allow(Reality).to receive(:first).with(reality_type: 'primary').and_return(nil)
        allow(Character).to receive(:first).with(forename: 'Monster:goblin').and_return(template_char)
      end

      it 'creates bare NPC FightParticipant without character_instance_id' do
        expect(FightParticipant).to receive(:create).with(
          satisfying { |attrs|
            attrs[:is_npc] == true &&
              !attrs.key?(:character_instance_id)
          }
        )

        allow(FightParticipant).to receive(:create).with(hash_including(character_instance_id: 1))

        described_class.create_fight_with_multiple_monsters!(delve, [monster], [participant])
      end
    end
  end

  describe 'battle map template wiring' do
    let(:real_room) do
      double('Room',
        id: 500,
        battle_map_ready?: false,
        room_hexes_dataset: double('HexDataset', delete: true, all: []),
        update: true
      )
    end
    let(:rooms_dataset) { double('Dataset', first: double('Room', id: 999)) }
    let(:location) { double('Location', rooms_dataset: rooms_dataset) }
    let(:delve) { double('Delve', id: 1, location: location) }
    let(:delve_room) do
      double('DelveRoom',
        id: 10,
        room: real_room,
        is_boss: false,
        room_type: 'corridor',
        available_exits: %w[north south]
      )
    end
    let(:character_instance) { double('CharacterInstance', id: 1) }
    let(:participant) do
      double('DelveParticipant',
        character_instance: character_instance,
        max_hp: 6,
        current_hp: 6,
        willpower_dice: 1.0
      )
    end
    let(:monster) do
      double('DelveMonster',
        id: 456,
        display_name: 'Goblin',
        monster_type: 'goblin',
        max_hp: 10,
        hp: 10,
        damage_bonus: 2
      )
    end
    let(:fight) { double('Fight', id: 42, update: true) }

    before do
      allow(Fight).to receive(:create).and_return(fight)
      allow(FightParticipant).to receive(:create)
      allow(monster).to receive(:respond_to?).with(:fight_id=).and_return(false)
    end

    describe 'integration: create_fight_with_multiple_monsters! with delve_room' do
      it 'uses the real room from delve_room for the fight' do
        allow(BattleMapTemplateService).to receive(:apply_random!).and_return(false)
        allow(BattleMapGeneratorService).to receive(:new).and_return(double(generate!: false))

        expect(Fight).to receive(:create).with(hash_including(
          room_id: 500
        )).and_return(fight)

        described_class.create_fight_with_multiple_monsters!(
          delve, [monster], [participant], delve_room: delve_room
        )
      end

      it 'falls back to location room when delve_room has no real room' do
        no_room_delve_room = double('DelveRoom', id: 10, room: nil)

        expect(Fight).to receive(:create).with(hash_including(
          room_id: 999
        )).and_return(fight)

        described_class.create_fight_with_multiple_monsters!(
          delve, [monster], [participant], delve_room: no_room_delve_room
        )
      end

      it 'applies template battle map before creating fight participants' do
        allow(BattleMapTemplateService).to receive(:delve_shape_key).with(delve_room).and_return('rect_vertical')
        allow(BattleMapTemplateService).to receive(:apply_random!).with(
          category: 'delve', shape_key: 'rect_vertical', room: real_room
        ).and_return(true)

        result = described_class.create_fight_with_multiple_monsters!(
          delve, [monster], [participant], delve_room: delve_room
        )

        expect(result[:fight_started]).to be true
        expect(BattleMapTemplateService).to have_received(:apply_random!)
      end

      it 'falls back to procedural generation when no template available' do
        allow(BattleMapTemplateService).to receive(:apply_random!).and_return(false)

        generator = double('BattleMapGeneratorService', generate!: true)
        allow(BattleMapGeneratorService).to receive(:new).with(real_room).and_return(generator)

        result = described_class.create_fight_with_multiple_monsters!(
          delve, [monster], [participant], delve_room: delve_room
        )

        expect(result[:fight_started]).to be true
        expect(generator).to have_received(:generate!)
      end

      it 'always applies the correct template even when room already has a battle map' do
        allow(real_room).to receive(:battle_map_ready?).and_return(true)

        expect(BattleMapTemplateService).to receive(:apply_random!)
          .with(category: 'delve', shape_key: anything, room: real_room)

        described_class.create_fight_with_multiple_monsters!(
          delve, [monster], [participant], delve_room: delve_room
        )
      end
    end
  end

  describe 'private methods' do
    describe 'fight_won_by_pcs?' do
      let(:alive_pc) { double('FightParticipant', is_npc: false, current_hp: 3) }
      let(:dead_pc) { double('FightParticipant', is_npc: false, current_hp: 0) }
      let(:npc) { double('FightParticipant', is_npc: true, current_hp: 5) }

      it 'returns true when any PC has positive HP' do
        fight = double('Fight', fight_participants: [alive_pc, npc])
        result = described_class.send(:fight_won_by_pcs?, fight)
        expect(result).to be true
      end

      it 'returns false when all PCs have zero HP' do
        fight = double('Fight', fight_participants: [dead_pc, npc])
        result = described_class.send(:fight_won_by_pcs?, fight)
        expect(result).to be false
      end
    end

    describe 'victory_message' do
      it 'includes monster name and bonus' do
        monster = double('DelveMonster', display_name: 'Dragon')
        msg = described_class.send(:victory_message, [monster], 100)

        expect(msg).to include('Dragon')
        expect(msg).to include('100')
        expect(msg).to include('slain!')
      end

      it 'uses default name when monsters is empty' do
        msg = described_class.send(:victory_message, [], 50)

        expect(msg).to include('The monster')
        expect(msg).to include('50')
      end
    end

    describe 'defeat_message' do
      it 'includes loot lost amount' do
        msg = described_class.send(:defeat_message, 75)

        expect(msg).to include('75')
        expect(msg).to include('defeated')
      end
    end
  end
end
