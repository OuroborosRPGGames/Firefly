# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Delve::DelveCommand do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Dungeon Entrance') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Dungeon', surname: 'Crawler') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    # Globally stub the SVG map service since most tests use mock participants
    allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil, metadata: {} })
    # Globally stub room data builder since most tests use mock participants/rooms
    allow(DelveMovementService).to receive(:build_current_room_data).and_return({})
  end

  def execute_command(args = nil)
    input = args.nil? ? 'delve' : "delve #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('delve')
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a.is_a?(Hash) ? a[:name] : a }
      expect(alias_names).to include('dv')
    end

    it 'has navigation category' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'has subcommands defined' do
      expect(described_class::SUBCOMMANDS).to include('enter', 'map', 'fight', 'flee')
    end

    it 'has direction aliases' do
      expect(described_class::DIRECTION_ALIASES['n']).to eq('north')
      expect(described_class::DIRECTION_ALIASES['s']).to eq('south')
    end
  end

  describe 'no subcommand' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'shows help text' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('Delve Commands')
      end
    end

    context 'when in a delve' do
      let(:delve) do
        double('Delve',
               id: 1,
               name: 'Dark Cave',
               difficulty: 'normal',
               total_levels: 3)
      end
      let(:delve_room) do
        double('DelveRoom',
               id: 99,
               respond_to?: false,
               explored: true,
               has_stairs_down?: false,
               has_monster?: false,
               exit_blocked?: false)
      end
      let(:delve_participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_level: 1,
               loot_collected: 50)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: delve_participant)))
        )
        allow(delve_room).to receive(:respond_to?).and_return(false)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
        allow(delve).to receive(:blocker_at).and_return(nil)
      end

      it 'shows delve dashboard' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('Dark Cave')
      end

      it 'includes time remaining' do
        result = execute_command(nil)

        expect(result[:message]).to include('15:30')
      end

      it 'includes HP display' do
        result = execute_command(nil)

        expect(result[:message]).to include('HP: 6/6')
      end

      it 'includes loot collected' do
        result = execute_command(nil)

        expect(result[:message]).to include('Loot: 50g')
      end
    end
  end

  describe 'subcommand: enter' do
    before do
      # No active participant initially
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
      )
    end

    context 'with name argument' do
      let(:delve) do
        instance_double(Delve,
                        id: 1,
                        name: 'Dark Cave',
                        destroy: true,
                        start!: true,
                        update: true)
      end
      let(:entrance_room) do
        double('DelveRoom',
               id: 99,
               update: true,
               explored: false,
               room_id: nil,
               has_stairs_down?: false,
               has_monster?: false,
               exit_blocked?: false)
      end
      let(:new_participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: entrance_room,
               time_remaining: 60,
               time_remaining_seconds: 3600,
               reload: nil,
               update: true,
               current_level: 1,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end
      let(:look_result) do
        double('Result', success: true, message: 'A dark chamber...', data: {})
      end

      before do
        allow(Delve).to receive(:create).and_return(delve)
        allow(DelveGeneratorService).to receive(:generate_level!)
        allow(delve).to receive(:entrance_room).and_return(entrance_room)
        allow(DelveParticipant).to receive(:create).and_return(new_participant)
        allow(DelveMovementService).to receive(:look).and_return(look_result)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'creates dungeon with given name' do
        expect(Delve).to receive(:create).with(hash_including(name: 'Dark Cave'))

        execute_command('enter Dark Cave')
      end

      it 'generates the first level' do
        expect(DelveGeneratorService).to receive(:generate_level!).with(delve, 1)

        execute_command('enter Dark Cave')
      end

      it 'creates a participant' do
        expect(DelveParticipant).to receive(:create).with(hash_including(
          delve_id: delve.id,
          character_instance_id: character_instance.id
        ))

        execute_command('enter Dark Cave')
      end

      it 'returns success with entry message' do
        result = execute_command('enter Dark Cave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('enter Dark Cave')
      end
    end

    context 'without name argument' do
      let(:delve) do
        instance_double(Delve,
                        id: 1,
                        name: 'Mysterious Dungeon',
                        destroy: true,
                        start!: true,
                        update: true)
      end
      let(:entrance_room) do
        double('DelveRoom', id: 99, update: true, room_id: nil, has_stairs_down?: false, has_monster?: false, exit_blocked?: false)
      end
      let(:new_participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: entrance_room,
               time_remaining: 60,
               time_remaining_seconds: 3600,
               reload: nil,
               update: true,
               current_level: 1,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end
      let(:look_result) do
        double('Result', success: true, message: 'A dark chamber...', data: {})
      end

      before do
        allow(Delve).to receive(:create).and_return(delve)
        allow(DelveGeneratorService).to receive(:generate_level!)
        allow(delve).to receive(:entrance_room).and_return(entrance_room)
        allow(DelveParticipant).to receive(:create).and_return(new_participant)
        allow(DelveMovementService).to receive(:look).and_return(look_result)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'uses default name' do
        expect(Delve).to receive(:create).with(hash_including(name: 'Mysterious Dungeon'))

        execute_command('enter')
      end
    end

    context 'when already in a delve' do
      let(:existing_delve) { double('Delve', name: 'Old Dungeon') }
      let(:existing_participant) do
        double('DelveParticipant', delve: existing_delve, current_level: 1, time_remaining: 15.5,
               time_remaining_seconds: 930, current_hp: 6, max_hp: 6, willpower_dice: 2, loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: existing_participant)))
        )
      end

      it 'returns error' do
        result = execute_command('enter New Dungeon')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already')
      end
    end

    context 'when generation fails' do
      let(:delve) do
        instance_double(Delve,
                        id: 1,
                        destroy: true,
                        start!: true,
                        update: true)
      end

      before do
        allow(Delve).to receive(:create).and_return(delve)
        allow(DelveGeneratorService).to receive(:generate_level!)
        allow(delve).to receive(:entrance_room).and_return(nil)
      end

      it 'marks delve as failed and returns error' do
        expect(delve).to receive(:update).with(status: 'failed')

        result = execute_command('enter Bad Dungeon')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Failed')
      end
    end
  end

  describe 'subcommand: movement (n/s/e/w)' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('n')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
      end

      context 'when movement succeeds' do
        let(:move_result) do
          double('Result',
                 success: true,
                 message: 'You move north into a dark corridor.',
                 data: { direction: 'north' })
        end

        before do
          allow(DelveMovementService).to receive(:move!).and_return(move_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
          allow(participant).to receive(:reload).and_return(participant)
          allow(delve).to receive(:tick_monster_movement!).and_return([])
        end

        it 'calls movement service' do
          expect(DelveMovementService).to receive(:move!).with(participant, 'north')

          execute_command('n')
        end

        it 'returns success with message' do
          result = execute_command('n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('move north')
        end

        it 'includes map data' do
          expect(DelveMapService).to receive(:render_minimap).with(participant)

          execute_command('n')
        end
      end

      context 'when movement fails' do
        let(:move_result) do
          double('Result',
                 success: false,
                 message: 'A wall blocks your path.',
                 data: nil)
        end

        before do
          allow(DelveMovementService).to receive(:move!).and_return(move_result)
        end

        it 'returns error' do
          result = execute_command('n')

          expect(result[:success]).to be false
          expect(result[:message]).to include('wall blocks')
        end
      end
    end
  end

  describe 'subcommand: map' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('map')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               time_remaining: 45.5,
               time_remaining_seconds: 2730,
               current_level: 1,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(DelveMapService).to receive(:render_minimap).and_return({ cells: [] })
        allow(DelveMapService).to receive(:render_ascii).and_return("###\n# #\n###")
      end

      it 'renders the minimap via HUD panel' do
        expect(DelveMapService).to receive(:render_minimap).with(participant)

        execute_command('map')
      end

      it 'returns success with empty message and data' do
        result = execute_command('map')

        expect(result[:success]).to be true
        expect(result[:data][:in_delve]).to be true
      end

      it 'includes map data in response' do
        result = execute_command('map')

        expect(result[:data]).to have_key(:map)
      end
    end
  end

  describe 'subcommand: fight' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('fight')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:participants_dataset) { double('Dataset') }
      let(:room_for_fight) { double('Room', id: 999) }
      let(:rooms_dataset) { double('RoomsDataset', first: room_for_fight) }
      let(:delve_location) { double('Location', rooms_dataset: rooms_dataset) }
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', location: delve_location, delve_participants_dataset: participants_dataset) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_level: 1,
               character_instance: character_instance,
               character_instance_id: character_instance.id,
               max_hp: 6,
               current_hp: 6,
               reload: nil,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(FightService).to receive(:find_active_fight).and_return(nil)
      end

      context 'when combat succeeds' do
        let(:monster) do
          double('DelveMonster',
                 id: 456,
                 display_name: 'Goblin',
                 max_hp: 10,
                 hp: 10,
                 damage_bonus: 2)
        end
        let(:fight_participant) do
          double('FightParticipant',
                 id: 1,
                 character_instance_id: character_instance.id)
        end
        let(:fight) { double('Fight', id: 1, fight_participants: [fight_participant]) }

        before do
          allow(fight_participant).to receive(:fight).and_return(fight)
          allow(delve).to receive(:monsters_in_room).with(delve_room).and_return([monster])
          allow(monster).to receive(:respond_to?).with(:fight_id=).and_return(true)
          allow(monster).to receive(:update)
          allow(DelveCombatService).to receive(:check_auto_combat!).and_return({
            fight_started: true,
            fight_id: 1,
            monster_names: ['Goblin'],
            monster_count: 1
          })
          allow(Fight).to receive(:[]).with(1).and_return(fight)
          allow(CombatQuickmenuHandler).to receive(:show_menu).and_return({ stage: 'main_menu' })
        end

        it 'creates fight via DelveCombatService' do
          expect(DelveCombatService).to receive(:check_auto_combat!)
            .with(delve, participant, delve_room)

          execute_command('fight')
        end

        it 'returns success with combat message' do
          result = execute_command('fight')

          expect(result[:success]).to be true
          expect(result[:message]).to include('COMBAT')
          expect(result[:message]).to include('Goblin')
        end
      end

      context 'when no monster present' do
        before do
          allow(delve).to receive(:monsters_in_room).with(delve_room).and_return([])
          allow(delve_room).to receive(:has_monster?).and_return(false)
          allow(DelveCombatService).to receive(:check_auto_combat!).and_return(nil)
        end

        it 'returns error' do
          result = execute_command('fight')

          expect(result[:success]).to be false
          expect(result[:message]).to include("nothing to fight")
        end
      end

      context 'when only static room monster is present' do
        let(:fight_participant) do
          double('FightParticipant',
                 id: 1,
                 character_instance_id: character_instance.id)
        end
        let(:fight) { double('Fight', id: 1, fight_participants: [fight_participant]) }

        before do
          allow(delve).to receive(:monsters_in_room).with(delve_room).and_return([])
          allow(delve_room).to receive(:has_monster?).and_return(true)
          allow(DelveCombatService).to receive(:check_auto_combat!).and_return({
            fight_started: true,
            fight_id: 1,
            monster_names: ['Goblin'],
            monster_count: 1
          })
          allow(Fight).to receive(:[]).with(1).and_return(fight)
          allow(CombatQuickmenuHandler).to receive(:show_menu).and_return({ stage: 'main_menu' })
        end

        it 'uses auto-combat flow so static monsters can be spawned' do
          expect(DelveCombatService).to receive(:check_auto_combat!).with(delve, participant, delve_room)

          result = execute_command('fight')

          expect(result[:success]).to be true
          expect(result[:message]).to include('COMBAT')
        end
      end

      context 'when already in combat' do
        let(:fight_participant) do
          double('FightParticipant',
                 id: 1,
                 character_instance_id: character_instance.id)
        end
        let(:existing_fight) { double('Fight', id: 5, fight_participants: [fight_participant]) }

        before do
          allow(FightService).to receive(:find_active_fight).and_return(existing_fight)
          allow(OutputHelper).to receive(:clear_pending_interactions)
          allow(CombatQuickmenuHandler).to receive(:show_menu).and_return({ stage: 'main_menu' })
        end

        it 'reopens combat menu instead of error' do
          result = execute_command('fight')

          expect(result[:success]).to be true
          expect(result[:message]).to include('already in combat')
        end
      end
    end
  end

  describe 'subcommand: status' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('status')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Dark Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_hp: 5,
               max_hp: 6,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
      end

      context 'when status succeeds' do
        let(:status_result) do
          double('Result',
                 success: true,
                 message: "Dark Dungeon - Level 1\nHP: 5/6\nTime: 30 minutes",
                 data: { hp: 5, max_hp: 6 })
        end

        before do
          allow(DelveActionService).to receive(:status).and_return(status_result)
        end

        it 'returns status info' do
          result = execute_command('status')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Dark Dungeon')
          expect(result[:message]).to include('5/6')
        end
      end
    end
  end

  describe 'subcommand: flee' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('flee')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
      end

      context 'when flee succeeds' do
        let(:flee_result) do
          double('Result',
                 success: true,
                 message: 'You escape the dungeon with 150 gold!',
                 data: { loot: 150 })
        end

        before do
          allow(DelveActionService).to receive(:flee!).and_return(flee_result)
        end

        it 'calls flee service' do
          expect(DelveActionService).to receive(:flee!).with(participant)

          execute_command('flee')
        end

        it 'returns success with loot info' do
          result = execute_command('flee')

          expect(result[:success]).to be true
          expect(result[:message]).to include('150 gold')
        end
      end
    end
  end

  describe 'subcommand: grab' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('grab')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(delve).to receive(:tick_monster_movement!).and_return([])
      end

      context 'when no treasure present' do
        before do
          allow(DelveTreasure).to receive(:first).and_return(nil)
        end

        it 'returns no treasure error' do
          result = execute_command('grab')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no treasure')
        end
      end

      context 'when treasure present' do
        let(:treasure) do
          double('DelveTreasure',
                 id: 1,
                 gold_value: 50)
        end
        let(:loot_result) do
          double('Result',
                 success: true,
                 message: 'You collect 50 gold!',
                 data: { gold: 50 })
        end

        before do
          allow(DelveTreasure).to receive(:first).and_return(treasure)
          allow(DelveTreasureService).to receive(:loot!).and_return(loot_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'collects treasure' do
          expect(DelveTreasureService).to receive(:loot!).with(participant, treasure)

          execute_command('grab')
        end

        it 'returns success' do
          result = execute_command('grab')

          expect(result[:success]).to be true
          expect(result[:message]).to include('50 gold')
        end
      end
    end
  end

  describe 'subcommand: recover' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('recover')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_hp: 3,
               max_hp: 6,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(delve).to receive(:tick_monster_movement!).and_return([])
      end

      context 'when recovery succeeds' do
        let(:recover_result) do
          double('Result',
                 success: true,
                 message: 'You rest and recover to full HP. (5 minutes)',
                 data: { hp_restored: 3 })
        end

        before do
          allow(DelveActionService).to receive(:recover!).and_return(recover_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'calls recover service' do
          expect(DelveActionService).to receive(:recover!).with(participant)

          execute_command('recover')
        end

        it 'returns recovery info' do
          result = execute_command('recover')

          expect(result[:success]).to be true
          expect(result[:message]).to include('recover')
        end

        it 'ticks monster movement' do
          expect(delve).to receive(:tick_monster_movement!).with(300)

          execute_command('recover')
        end
      end
    end
  end

  describe 'subcommand: solve (puzzles)' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('solve answer')

        expect(result[:success]).to be false
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
      end

      context 'when no puzzle present' do
        before do
          allow(DelvePuzzle).to receive(:first).and_return(nil)
        end

        it 'returns no puzzle error' do
          result = execute_command('solve answer')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no puzzle')
        end
      end

      context 'when puzzle present' do
        let(:puzzle) do
          double('DelvePuzzle',
                 id: 1,
                 puzzle_type: 'riddle',
                 answer: 'shadow',
                 solved?: false)
        end

        before do
          allow(DelvePuzzle).to receive(:first).and_return(puzzle)
        end

        context 'with correct answer' do
          let(:solve_result) do
            double('Result',
                   success: true,
                   message: 'You solved the puzzle!',
                   data: { solved: true })
          end

          before do
            allow(DelvePuzzleService).to receive(:attempt!).and_return(solve_result)
            allow(DelveMapService).to receive(:render_minimap).and_return({})
          end

          it 'attempts to solve' do
            expect(DelvePuzzleService).to receive(:attempt!).with(participant, puzzle, 'shadow')

            execute_command('solve shadow')
          end

          it 'returns success' do
            result = execute_command('solve shadow')

            expect(result[:success]).to be true
            expect(result[:message]).to include('solved')
          end
        end

        context 'with incorrect answer' do
          let(:solve_result) do
            double('Result',
                   success: false,
                   message: 'That is incorrect.',
                   data: { solved: false })
          end

          before do
            allow(DelvePuzzleService).to receive(:attempt!).and_return(solve_result)
            allow(DelveMapService).to receive(:render_minimap).and_return({})
          end

          it 'returns success with failure message' do
            result = execute_command('solve wrong')

            # Puzzle solve attempts always return success so the message
            # appears in game output without "Error:" prefix
            expect(result[:success]).to be true
            expect(result[:message]).to include('incorrect')
          end
        end

        context 'when puzzle already solved' do
          before do
            allow(puzzle).to receive(:solved?).and_return(true)
          end

          it 'returns error' do
            result = execute_command('solve anything')

            expect(result[:success]).to be false
            expect(result[:message]).to include('already been solved')
          end
        end

        context 'without answer argument' do
          let(:display_data) { { puzzle_type: 'riddle', description: 'What has no light?' } }

          before do
            allow(DelvePuzzleService).to receive(:get_display).and_return(display_data)
            allow(puzzle).to receive(:description).and_return('What has no light?')
            allow(DelveMapService).to receive(:render_minimap).and_return({})
            allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil })
            allow(DelveMovementService).to receive(:build_current_room_data).and_return({})
          end

          it 'opens the puzzle UI instead of showing error' do
            result = execute_command('solve')

            expect(result[:success]).to be true
            expect(result[:type]).to eq(:puzzle)
          end
        end
      end
    end
  end

  describe 'subcommand: focus' do
    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end
      let(:focus_result) do
        double('Result',
               success: true,
               message: 'You focus your mind, gaining a willpower die. (30 seconds)',
               data: { willpower_gained: 1 })
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(DelveActionService).to receive(:focus!).and_return(focus_result)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'calls focus service' do
        expect(DelveActionService).to receive(:focus!).with(participant)

        execute_command('focus')
      end

      it 'returns success' do
        result = execute_command('focus')

        expect(result[:success]).to be true
        expect(result[:message]).to include('willpower')
      end

      it 'ticks monster movement for configured focus time' do
        expected_seconds = ::Delve.action_time_seconds(:focus) || ::Delve::ACTION_TIMES_SECONDS[:focus]
        expect(delve).to receive(:tick_monster_movement!).with(expected_seconds)

        execute_command('focus')
      end
    end
  end

  describe 'subcommand: study' do
    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(delve).to receive(:tick_monster_movement!).and_return([])
      end

      context 'without target' do
        it 'returns error with hint' do
          result = execute_command('study')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Study what?')
        end
      end

      context 'studying a direction with trap' do
        let(:trap) do
          double('DelveTrap',
                 id: 1,
                 description: 'A spike trap',
                 disabled?: false)
        end
        let(:sequence_data) do
          {
            formatted: '1:Safe 2:DANGER 3:Safe',
            start_point: 1,
            length: 3
          }
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
          allow(DelveTrapService).to receive(:get_initial_sequence).and_return(sequence_data)
          allow(participant).to receive(:has_passed_trap?).and_return(false)
        end

        it 'returns trap info' do
          result = execute_command('study n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('spike trap')
          expect(result[:message]).to include('Safe')
        end
      end

      context 'studying a direction with blocker' do
        let(:blocker) do
          double('DelveBlocker',
                 description: 'A heavy boulder',
                 blocker_type: 'heavy_object',
                 cleared?: false,
                 stat_for_check: 'strength',
                 effective_difficulty: 15,
                 easier_attempts: 0)
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
          allow(delve).to receive(:blocker_at).and_return(blocker)
        end

        it 'returns blocker info' do
          result = execute_command('study n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('boulder')
          expect(result[:message]).to include('DC 15')
        end
      end

      context 'studying a monster' do
        let(:monster) do
          double('DelveMonster',
                 monster_type: 'Goblin')
        end
        let(:study_result) do
          double('Result',
                 success: true,
                 message: 'You study the Goblin, gaining +2 to your next attack.',
                 data: { bonus: 2 })
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
          allow(delve).to receive(:blocker_at).and_return(nil)
          allow(delve).to receive(:monsters_in_room).and_return([monster])
          allow(DelveActionService).to receive(:study!).and_return(study_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'calls study service' do
          expect(DelveActionService).to receive(:study!).with(participant, 'Goblin')

          execute_command('study goblin')
        end
      end
    end
  end

  describe 'unknown subcommand' do
    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
      )
    end

    it 'returns error with hint' do
      result = execute_command('invalid')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Unknown subcommand')
    end
  end

  describe 'subcommand: down (descend)' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('down')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
      end

      context 'when descend succeeds' do
        let(:descend_result) do
          double('Result',
                 success: true,
                 message: 'You descend to level 2...',
                 data: { new_level: 2 })
        end

        before do
          allow(DelveMovementService).to receive(:descend!).and_return(descend_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'calls descend service' do
          expect(DelveMovementService).to receive(:descend!).with(participant)

          execute_command('down')
        end

        it 'returns success with level info' do
          result = execute_command('down')

          expect(result[:success]).to be true
          expect(result[:message]).to include('descend')
        end

        it 'includes map data' do
          result = execute_command('down')

          expect(result[:data]).to have_key(:map)
        end
      end

      context 'when descend fails' do
        let(:descend_result) do
          double('Result',
                 success: false,
                 message: 'There are no stairs here.')
        end

        before do
          allow(DelveMovementService).to receive(:descend!).and_return(descend_result)
        end

        it 'returns error' do
          result = execute_command('down')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no stairs')
        end
      end
    end
  end

  describe 'subcommand: fullmap' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('fullmap')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end
      let(:full_map_data) { { cells: [], explored_rooms: 10 } }

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(DelveMapService).to receive(:render_full_map).and_return(full_map_data)
      end

      it 'renders full map' do
        expect(DelveMapService).to receive(:render_full_map).with(participant)

        execute_command('fullmap')
      end

      it 'returns success with map data' do
        result = execute_command('fullmap')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Explored Map')
        expect(result[:data][:map]).to eq(full_map_data)
      end
    end
  end

  describe 'subcommand: look' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('look')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
      end

      context 'when look succeeds' do
        let(:look_result) do
          double('Result',
                 success: true,
                 message: 'A dark corridor stretches before you...',
                 data: { room_type: 'corridor' })
        end

        before do
          allow(DelveMovementService).to receive(:look).and_return(look_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'calls look service' do
          expect(DelveMovementService).to receive(:look).with(participant)

          execute_command('look')
        end

        it 'returns room description' do
          result = execute_command('look')

          expect(result[:success]).to be true
          expect(result[:message]).to include('dark corridor')
        end

        it 'includes map data' do
          result = execute_command('look')

          expect(result[:data]).to have_key(:map)
        end
      end

      context 'when look fails' do
        let(:look_result) do
          double('Result',
                 success: false,
                 message: 'You cannot see anything.')
        end

        before do
          allow(DelveMovementService).to receive(:look).and_return(look_result)
        end

        it 'returns error' do
          result = execute_command('look')

          expect(result[:success]).to be false
          expect(result[:message]).to include('cannot see')
        end
      end
    end
  end

  describe 'subcommand: easier' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('easier n')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
      end

      context 'without direction argument' do
        it 'returns error' do
          result = execute_command('easier')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Which direction')
        end
      end

      context 'with no obstacle in direction' do
        before do
          allow(delve).to receive(:blocker_at).and_return(nil)
        end

        it 'returns error' do
          result = execute_command('easier n')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no obstacle')
        end
      end

      context 'with already cleared obstacle' do
        let(:blocker) do
          double('DelveBlocker',
                 cleared?: true)
        end

        before do
          allow(delve).to receive(:blocker_at).and_return(blocker)
        end

        it 'returns error' do
          result = execute_command('easier n')

          expect(result[:success]).to be false
          expect(result[:message]).to include('already been cleared')
        end
      end

      context 'with valid obstacle' do
        let(:blocker) do
          double('DelveBlocker',
                 cleared?: false)
        end
        let(:easier_result) do
          double('Result',
                 success: true,
                 message: 'You study the obstacle, lowering its DC by 1.',
                 data: { new_dc: 14 })
        end

        before do
          allow(delve).to receive(:blocker_at).and_return(blocker)
          allow(DelveSkillCheckService).to receive(:make_easier!).and_return(easier_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'calls make_easier service' do
          expect(DelveSkillCheckService).to receive(:make_easier!).with(participant, blocker)

          execute_command('easier n')
        end

        it 'returns success' do
          result = execute_command('easier n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('lowering')
        end

        it 'ticks monster movement' do
          expect(delve).to receive(:tick_monster_movement!).with(30)

          execute_command('easier n')
        end
      end
    end
  end

  describe 'subcommand: listen' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('listen n')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
      let(:delve_room) { double('DelveRoom', id: 99, has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0,
               trap_observation_state: nil,
               spend_time_seconds!: :ok,
               set_trap_observation_state!: true)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
      end

      context 'without direction argument and no traps' do
        before do
          allow(DelveTrap).to receive(:where).and_return(
            double('Dataset', select_map: [])
          )
        end

        it 'returns error about no traps' do
          result = execute_command('listen')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no traps')
        end
      end

      context 'without direction argument but traps exist' do
        before do
          allow(DelveTrap).to receive(:where).and_return(
            double('Dataset', select_map: %w[north south])
          )
        end

        it 'returns error with trapped directions' do
          result = execute_command('listen')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Specify a direction')
        end
      end

      context 'with direction but no trap' do
        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        end

        it 'returns error' do
          result = execute_command('listen n')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no trap')
        end
      end

      context 'with disabled trap' do
        let(:trap) do
          double('DelveTrap',
                 id: 1,
                 disabled?: true)
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        end

        it 'returns error' do
          result = execute_command('listen n')

          expect(result[:success]).to be false
          expect(result[:message]).to include('disabled')
        end
      end

      context 'with active trap - first observation' do
        let(:trap) do
          double('DelveTrap',
                 id: 1,
                 disabled?: false)
        end
        let(:sequence_data) do
          {
            formatted: '1:Safe 2:DANGER 3:Safe 4:DANGER',
            start_point: 1,
            length: 4
          }
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
          allow(DelveTrapService).to receive(:get_initial_sequence).and_return(sequence_data)
          allow(participant).to receive(:has_passed_trap?).and_return(false)
        end

        it 'returns trap sequence' do
          result = execute_command('listen n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Safe')
          expect(result[:message]).to include('DANGER')
        end
      end
    end
  end

  describe 'subcommand: go' do
    context 'when not in a delve' do
      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
        )
      end

      it 'returns error' do
        result = execute_command('go n 3')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not currently in a delve')
      end
    end

    context 'when in a delve' do
      let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
      let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
      let(:participant) do
        double('DelveParticipant',
               id: 1,
               delve: delve,
               current_room: delve_room,
               reload: nil,
               current_level: 1,
               time_remaining: 15.5,
               time_remaining_seconds: 930,
               current_hp: 6,
               max_hp: 6,
               willpower_dice: 2,
               loot_collected: 0)
      end

      before do
        allow(DelveParticipant).to receive(:where).and_return(
          double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
        )
        allow(participant).to receive(:reload).and_return(participant)
        allow(delve).to receive(:tick_monster_movement!).and_return([])
      end

      context 'without arguments' do
        it 'returns usage error' do
          result = execute_command('go')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Usage')
        end
      end

      context 'with no trap in direction' do
        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        end

        it 'returns error' do
          result = execute_command('go n 3')

          expect(result[:success]).to be false
          expect(result[:message]).to include('no trap')
        end
      end

      context 'with trap but no pulse number' do
        let(:trap) do
          double('DelveTrap',
                 id: 5,
                 disabled?: false)
        end
        let(:sequence_data) do
          {
            formatted: '1:Safe 2:DANGER 3:Safe',
            start_point: 1,
            length: 3
          }
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
          allow(DelveTrapService).to receive(:get_initial_sequence).and_return(sequence_data)
          allow(participant).to receive(:has_passed_trap?).and_return(false)
        end

        it 'shows trap sequence' do
          result = execute_command('go n')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Safe')
        end
      end

      context 'with invalid pulse number' do
        let(:trap) do
          double('DelveTrap',
                 id: 5,
                 disabled?: false)
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        end

        it 'returns error for zero' do
          result = execute_command('go n 0')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Invalid pulse')
        end

        it 'returns error for negative' do
          result = execute_command('go n -1')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Invalid pulse')
        end
      end

      context 'with valid pulse number' do
        let(:trap) do
          double('DelveTrap',
                 id: 5,
                 disabled?: false)
        end
        let(:move_result) do
          double('Result',
                 success: true,
                 message: 'You time your passage perfectly and slip through!',
                 data: { direction: 'north' })
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
          allow(DelveMovementService).to receive(:move!).and_return(move_result)
          allow(DelveMapService).to receive(:render_minimap).and_return({})
        end

        it 'attempts to pass through trap' do
          expect(DelveMovementService).to receive(:move!).with(
            participant,
            'north',
            trap_pulse: 3,
            trap_sequence_start: anything
          )

          execute_command('go n 3')
        end

        it 'returns success on safe passage' do
          result = execute_command('go n 3')

          expect(result[:success]).to be true
          expect(result[:message]).to include('slip through')
        end
      end

      context 'when trap triggers' do
        let(:trap) do
          double('DelveTrap',
                 id: 5,
                 disabled?: false)
        end
        let(:move_result) do
          double('Result',
                 success: false,
                 message: 'The trap triggers! You take 2 damage.')
        end

        before do
          allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
          allow(DelveMovementService).to receive(:move!).and_return(move_result)
        end

        it 'returns failure' do
          result = execute_command('go n 3')

          expect(result[:success]).to be false
          expect(result[:message]).to include('trap triggers')
        end
      end
    end
  end

  describe 'dashboard with various room contents' do
    let(:delve) do
      double('Delve',
             id: 1,
             name: 'Rich Dungeon',
             difficulty: 'hard',
             total_levels: 5)
    end
    let(:delve_room) do
      double('DelveRoom',
             id: 99,
             explored: true,
             available_exits: [],
             monster_type: 'Orc',
             has_stairs_down?: false,
             has_monster?: false,
             exit_blocked?: false)
    end
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_hp: 4,
             max_hp: 6,
             willpower_dice: 3,
             time_remaining: 30.25,
               time_remaining_seconds: 1815,
             current_level: 2,
             loot_collected: 200)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(delve).to receive(:blocker_at).and_return(nil)
    end

    context 'with monster in room' do
      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:has_monster?).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'shows monster info' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('Monster: Orc')
      end

      it 'shows fight action' do
        result = execute_command(nil)

        expect(result[:message]).to include('[fight]')
      end

      it 'shows study action' do
        result = execute_command(nil)

        expect(result[:message]).to include('[study Orc]')
      end
    end

    context 'with treasure in room' do
      let(:treasure) do
        double('DelveTreasure',
               looted?: false)
      end

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(treasure)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'shows treasure available' do
        result = execute_command(nil)

        expect(result[:message]).to include('Treasure available')
      end

      it 'shows grab action' do
        result = execute_command(nil)

        expect(result[:message]).to include('[grab]')
      end
    end

    context 'with unsolved puzzle in room' do
      let(:puzzle) do
        double('DelvePuzzle',
               solved?: false)
      end

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(puzzle)
      end

      it 'shows puzzle unsolved' do
        result = execute_command(nil)

        expect(result[:message]).to include('Puzzle unsolved')
      end

      it 'shows solve action' do
        result = execute_command(nil)

        expect(result[:message]).to include('[solve <answer>]')
      end
    end

    context 'with stairs down' do
      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(true)
        allow(delve_room).to receive(:has_stairs_down?).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'shows stairs to next level' do
        result = execute_command(nil)

        expect(result[:message]).to include('[D] Down')
        expect(result[:message]).to include('level 3')
      end
    end

    context 'with blocked exit' do
      let(:adjacent_room) { double('DelveRoom', id: 100) }
      let(:north_blocker) { double('DelveBlocker', cleared?: false, stat_for_check: 'strength', effective_difficulty: 12) }

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(true)
        allow(delve_room).to receive(:exit_blocked?).with('north').and_return(true)
        allow(delve_room).to receive(:exit_blocked?).with('east').and_return(false)
        allow(delve_room).to receive(:exit_blocked?).with('south').and_return(false)
        allow(delve_room).to receive(:exit_blocked?).with('west').and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).with('north').and_return(adjacent_room)
        allow(delve_room).to receive(:adjacent_room).with('east').and_return(adjacent_room)
        allow(delve_room).to receive(:adjacent_room).with('south').and_return(nil)
        allow(delve_room).to receive(:adjacent_room).with('west').and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'north').and_return(north_blocker)
        allow(delve).to receive(:blocker_at).with(delve_room, 'east').and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'south').and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'west').and_return(nil)
      end

      it 'shows blocked direction' do
        result = execute_command(nil)

        expect(result[:message]).to include('[N] North - Blocked (strength DC 12)')
      end

      it 'shows clear direction' do
        result = execute_command(nil)

        expect(result[:message]).to include('[E] East - Clear')
      end
    end

    context 'with trap in direction' do
      let(:trap) do
        double('DelveTrap',
               description: 'Poison darts')
      end

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'north').and_return(trap)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'east').and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'south').and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'west').and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'shows trap detected' do
        result = execute_command(nil)

        expect(result[:message]).to include('[N] North - Trap detected')
      end
    end

    context 'when injured' do
      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'shows recover action when HP < max' do
        result = execute_command(nil)

        expect(result[:message]).to include('[recover]')
      end

      it 'shows HP as 4/6' do
        result = execute_command(nil)

        expect(result[:message]).to include('HP: 4/6')
      end
    end
  end

  describe 'movement direction aliases' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:move_result) do
      double('Result',
             success: true,
             message: 'You move...',
             data: { direction: 'south' })
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveMovementService).to receive(:move!).and_return(move_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(delve).to receive(:tick_monster_movement!).and_return([])
    end

    it 'handles south alias' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'south')
      execute_command('s')
    end

    it 'handles east alias' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'east')
      execute_command('e')
    end

    it 'handles west alias' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'west')
      execute_command('w')
    end

    it 'handles full direction name north' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'north')
      execute_command('north')
    end

    it 'handles full direction name south' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'south')
      execute_command('south')
    end

    it 'handles full direction name east' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'east')
      execute_command('east')
    end

    it 'handles full direction name west' do
      expect(DelveMovementService).to receive(:move!).with(participant, 'west')
      execute_command('west')
    end
  end

  describe 'study puzzle' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil })
      allow(DelveMovementService).to receive(:build_current_room_data).and_return({})
    end

    context 'when no puzzle exists' do
      before do
        allow(DelvePuzzle).to receive(:first).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('study puzzle')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no puzzle')
      end
    end

    context 'when puzzle already solved' do
      let(:puzzle) do
        double('DelvePuzzle',
               solved?: true)
      end

      before do
        allow(DelvePuzzle).to receive(:first).and_return(puzzle)
      end

      it 'returns error' do
        result = execute_command('study puzzle')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already been solved')
      end
    end

    context 'when puzzle exists and unsolved' do
      let(:puzzle) do
        double('DelvePuzzle',
               solved?: false,
               puzzle_type: 'riddle',
               difficulty: 'medium',
               hints_used: 1,
               description: 'What walks on four legs in the morning?')
      end
      let(:display_data) { { puzzle_type: 'riddle', description: 'What walks on four legs in the morning?' } }

      before do
        allow(DelvePuzzle).to receive(:first).and_return(puzzle)
        allow(DelvePuzzleService).to receive(:get_display).and_return(display_data)
      end

      it 'returns puzzle info routed to observation panel' do
        result = execute_command('study puzzle')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:puzzle)
        expect(result[:output_category]).to eq(:info)
      end
    end
  end

  describe 'study monster with no enemies' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      allow(delve).to receive(:blocker_at).and_return(nil)
      allow(delve).to receive(:monsters_in_room).and_return([])
    end

    it 'returns error when no enemies' do
      result = execute_command('study goblin')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no enemies')
    end
  end

  describe 'study monster with wrong type' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:monster) do
      double('DelveMonster',
             monster_type: 'Orc')
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      allow(delve).to receive(:blocker_at).and_return(nil)
      allow(delve).to receive(:monsters_in_room).and_return([monster])
    end

    it 'returns error with available monsters' do
      result = execute_command('study goblin')

      expect(result[:success]).to be false
      expect(result[:message]).to include('goblin')
      expect(result[:message]).to include('Orc')
    end
  end

  describe 'study direction with nothing blocking' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      allow(delve).to receive(:blocker_at).and_return(nil)
    end

    it 'returns error about nothing blocking' do
      result = execute_command('study north')

      expect(result[:success]).to be false
      expect(result[:message]).to include('nothing blocking')
    end
  end

  describe 'study experienced trap' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:trap) do
      double('DelveTrap',
             id: 1,
             description: 'A spike trap',
             disabled?: false)
    end
    let(:sequence_data) do
      {
        formatted: '1:Safe 2:DANGER 3:Safe',
        start_point: 1,
        length: 3
      }
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
      allow(DelveTrapService).to receive(:get_initial_sequence).and_return(sequence_data)
      allow(participant).to receive(:has_passed_trap?).and_return(true)
    end

    it 'shows experienced hint' do
      result = execute_command('study n')

      expect(result[:success]).to be true
      expect(result[:message]).to include("You've passed this trap before")
    end
  end

  describe 'exit and leave aliases for flee' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:flee_result) do
      double('Result',
             success: true,
             message: 'You flee with your loot!',
             data: { loot: 100 })
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(DelveActionService).to receive(:flee!).and_return(flee_result)
    end

    it 'handles exit alias' do
      expect(DelveActionService).to receive(:flee!).with(participant)
      execute_command('exit')
    end

    it 'handles leave alias' do
      expect(DelveActionService).to receive(:flee!).with(participant)
      execute_command('leave')
    end
  end

  describe 'take alias for grab' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveTreasure).to receive(:first).and_return(nil)
    end

    it 'handles take as grab alias' do
      result = execute_command('take')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no treasure')
    end
  end

  describe 'rest alias for recover' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:recover_result) do
      double('Result',
             success: true,
             message: 'You rest and recover.',
             data: {})
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveActionService).to receive(:recover!).and_return(recover_result)
      allow(delve).to receive(:tick_monster_movement!).and_return([])
      allow(DelveMapService).to receive(:render_minimap).and_return({})
    end

    it 'routes rest to recover action' do
      result = command.execute('rest')

      expect(DelveActionService).to have_received(:recover!).with(participant)
      expect(result[:success]).to be true
      expect(result[:message]).to include('recover')
    end
  end

  describe 'd alias for down' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:descend_result) do
      double('Result',
             success: true,
             message: 'You descend...',
             data: { new_level: 2 })
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveMovementService).to receive(:descend!).and_return(descend_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
    end

    it 'routes d to descend' do
      result = command.execute('d')

      expect(DelveMovementService).to have_received(:descend!).with(participant)
      expect(result[:success]).to be true
      expect(result[:message]).to include('descend')
    end
  end

  describe 'l alias for look' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:look_result) do
      double('Result',
             success: true,
             message: 'You look around...',
             data: {})
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(DelveMovementService).to receive(:look).and_return(look_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
    end

    it 'routes l to look' do
      result = command.execute('l')

      expect(DelveMovementService).to have_received(:look).with(participant)
      expect(result[:success]).to be true
      expect(result[:message]).to include('look around')
    end
  end

  describe 'error handling in dashboard' do
    let(:delve) do
      double('Delve',
             id: 1,
             name: 'Test Dungeon')
    end
    let(:delve_room) do
      double('DelveRoom',
             id: 99,
             explored: true,
             available_exits: [],
             has_stairs_down?: false,
             has_monster?: false,
             exit_blocked?: false)
    end
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 0,
             time_remaining: 30.0,
               time_remaining_seconds: 1800,
             current_level: 1,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
      allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
      allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
      allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
      allow(delve).to receive(:blocker_at).and_return(nil)
    end

    context 'when adjacent_room raises error' do
      before do
        allow(delve_room).to receive(:adjacent_room).and_raise(StandardError.new('Room lookup failed'))
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'handles error gracefully' do
        result = execute_command(nil)

        expect(result[:success]).to be true
      end
    end

    context 'when treasure query raises error' do
      before do
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_raise(StandardError.new('DB error'))
        allow(DelvePuzzle).to receive(:first).and_return(nil)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'handles error gracefully' do
        result = execute_command(nil)

        expect(result[:success]).to be true
      end
    end

    context 'when puzzle query raises error' do
      before do
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_raise(StandardError.new('DB error'))
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'handles error gracefully' do
        result = execute_command(nil)

        expect(result[:success]).to be true
      end
    end

    context 'when map render raises error' do
      before do
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveTreasure).to receive(:first).and_return(nil)
        allow(DelvePuzzle).to receive(:first).and_return(nil)
        allow(DelveMapService).to receive(:render_minimap).and_raise(StandardError.new('Render error'))
      end

      it 'handles error gracefully' do
        result = execute_command(nil)

        expect(result[:success]).to be true
      end
    end
  end

  describe 'respond helper with map render error' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:focus_result) do
      double('Result',
             success: true,
             message: 'You focus...',
             data: {})
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveActionService).to receive(:focus!).and_return(focus_result)
      allow(DelveMapService).to receive(:render_minimap).and_raise(StandardError.new('Map error'))
    end

    it 'handles map render error in respond helper' do
      result = execute_command('focus')

      expect(result[:success]).to be true
      expect(result[:data][:map]).to be_nil
    end
  end

  describe 'failed action results' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon', tick_monster_movement!: []) }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    context 'focus failure' do
      let(:focus_result) do
        double('Result',
               success: false,
               message: 'You cannot focus right now.')
      end

      before do
        allow(DelveActionService).to receive(:focus!).and_return(focus_result)
      end

      it 'returns error' do
        result = execute_command('focus')

        expect(result[:success]).to be false
        expect(result[:message]).to include('cannot focus')
      end
    end

    context 'status failure' do
      let(:status_result) do
        double('Result',
               success: false,
               message: 'Cannot get status.')
      end

      before do
        allow(DelveActionService).to receive(:status).and_return(status_result)
      end

      it 'returns error' do
        result = execute_command('status')

        expect(result[:success]).to be false
      end
    end

    context 'flee failure' do
      let(:flee_result) do
        double('Result',
               success: false,
               message: 'Cannot flee from combat.')
      end

      before do
        allow(DelveActionService).to receive(:flee!).and_return(flee_result)
      end

      it 'returns error' do
        result = execute_command('flee')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Cannot flee')
      end
    end
  end

  describe 'monster ticking with collisions' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:character_inst) { double('CharacterInstance', id: 31, character_instance_id: 31) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             character_instance: character_inst,
             character_instance_id: 31,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:monster) { double('DelveMonster', id: 1, monster_type: 'Goblin') }
    let(:collision) do
      {
        type: :collision,
        monster: monster,
        room: delve_room,
        participants: [participant]
      }
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(delve).to receive(:tick_monster_movement!).and_return([collision])
      allow(DelveCombatService).to receive(:create_fight!)
      allow(FightService).to receive(:find_active_fight).and_return(nil)
    end

    context 'when recover triggers monster collision' do
      let(:recover_result) do
        double('Result',
               success: true,
               message: 'You recover...',
               data: {})
      end

      before do
        allow(DelveActionService).to receive(:recover!).and_return(recover_result)
        allow(DelveMapService).to receive(:render_minimap).and_return({})
      end

      it 'starts combat with collided monster' do
        expect(DelveCombatService).to receive(:create_fight!).with(delve, monster, [participant], delve_room: delve_room)

        execute_command('recover')
      end
    end
  end

  describe 'tick_monsters_if_needed with short time' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(command).to receive(:participant).and_return(participant)
    end

    it 'does not tick monsters when below configured threshold' do
      allow(GameSetting).to receive(:integer).with('delve_monster_move_threshold').and_return(10)
      expect(delve).not_to receive(:tick_monster_movement!)

      result = command.send(:tick_monsters_if_needed, 5)
      expect(result).to be_nil
    end

    it 'ticks monsters when equal to configured threshold' do
      allow(GameSetting).to receive(:integer).with('delve_monster_move_threshold').and_return(5)
      expect(delve).to receive(:tick_monster_movement!).with(5).and_return([])

      result = command.send(:tick_monsters_if_needed, 5)
      expect(result).to be_nil
    end
  end

  # ===== EDGE CASE TESTS FOR ADDITIONAL COVERAGE =====

  describe 'subcommand: study edge cases' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil })
      allow(DelveMovementService).to receive(:build_current_room_data).and_return({})
    end

    context 'with empty target' do
      it 'returns error about what to study' do
        result = execute_command('study')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Study what?')
      end

      it 'returns error for whitespace-only target' do
        result = execute_command('study    ')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Study what?')
      end
    end

    context 'studying puzzle' do
      it 'returns error when no puzzle in room' do
        allow(DelvePuzzle).to receive(:first).and_return(nil)

        result = execute_command('study puzzle')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no puzzle')
      end

      it 'returns error when puzzle already solved' do
        puzzle = double('DelvePuzzle', solved?: true)
        allow(DelvePuzzle).to receive(:first).and_return(puzzle)

        result = execute_command('study puzzle')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already been solved')
      end

      it 'shows puzzle info when puzzle exists' do
        puzzle = double('DelvePuzzle',
                        solved?: false,
                        puzzle_type: 'riddle',
                        difficulty: 'medium',
                        hints_used: 1,
                        description: 'A mysterious riddle')
        allow(DelvePuzzle).to receive(:first).and_return(puzzle)
        allow(DelvePuzzleService).to receive(:get_display).and_return({ puzzle_type: 'riddle' })

        result = execute_command('study puzzle')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:puzzle)
        expect(result[:output_category]).to eq(:info)
      end
    end

    context 'studying direction with trap' do
      let(:trap) { double('DelveTrap', id: 10, disabled?: false, description: 'A swinging blade') }

      before do
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        allow(DelveTrapService).to receive(:get_initial_sequence).and_return({
          formatted: '1:S 2:D 3:S',
          start_point: 1,
          length: 3
        })
        allow(participant).to receive(:has_passed_trap?).and_return(false)
        allow(delve).to receive(:blocker_at).and_return(nil)
      end

      it 'shows trap sequence for first-time player' do
        result = execute_command('study north')

        expect(result[:success]).to be true
        expect(result[:message]).to include('trap')
        expect(result[:message]).to include('First time through')
      end

      it 'shows experienced hint for repeat player' do
        allow(participant).to receive(:has_passed_trap?).and_return(true)

        result = execute_command('study n')

        expect(result[:success]).to be true
        expect(result[:message]).to include('passed this trap before')
      end
    end

    context 'studying direction with blocker' do
      let(:blocker) do
        double('DelveBlocker',
               cleared?: false,
               description: 'A heavy barricade',
               blocker_type: 'barricade',
               stat_for_check: 'STR',
               effective_difficulty: 15,
               easier_attempts: 2)
      end

      before do
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(delve).to receive(:blocker_at).and_return(blocker)
      end

      it 'shows blocker info' do
        result = execute_command('study east')

        expect(result[:success]).to be true
        expect(result[:message]).to include('obstacle')
        expect(result[:message]).to include('STR vs DC 15')
        expect(result[:message]).to include('Easier attempts: 2')
      end
    end

    context 'studying direction with nothing' do
      before do
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(delve).to receive(:blocker_at).and_return(nil)
      end

      it 'returns error about nothing blocking' do
        result = execute_command('study west')

        expect(result[:success]).to be false
        expect(result[:message]).to include('nothing blocking')
      end
    end

    context 'studying monster' do
      it 'returns error when no monsters in room' do
        allow(delve).to receive(:monsters_in_room).and_return([])

        result = execute_command('study goblin')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no enemies here')
      end

      it 'returns error when monster type not found' do
        monster = double('DelveMonster', monster_type: 'Skeleton')
        allow(delve).to receive(:monsters_in_room).and_return([monster])

        result = execute_command('study goblin')

        expect(result[:success]).to be false
        # Message includes HTML encoding (&#39; for apostrophe)
        expect(result[:message]).to match(/No.*goblin.*here/)
        expect(result[:message]).to include('Skeleton')
      end

      it 'calls study action when monster found' do
        monster = double('DelveMonster', monster_type: 'Goblin')
        allow(delve).to receive(:monsters_in_room).and_return([monster])

        study_result = double('Result', success: true, message: 'You study the Goblin...', data: {})
        allow(DelveActionService).to receive(:study!).and_return(study_result)
        allow(delve).to receive(:tick_monster_movement!).and_return([])
        allow(DelveMapService).to receive(:render_minimap).and_return({})

        result = execute_command('study goblin')

        expect(result[:success]).to be true
      end
    end
  end



  describe 'subcommand: solve edge cases' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'opens puzzle UI without answer when puzzle exists' do
      puzzle = double('DelvePuzzle',
                      solved?: false,
                      description: 'A riddle awaits')
      allow(DelvePuzzle).to receive(:first).and_return(puzzle)
      allow(DelvePuzzleService).to receive(:get_display).and_return({ puzzle_type: 'riddle' })
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(DelveMapPanelService).to receive(:render).and_return({ svg: nil })
      allow(DelveMovementService).to receive(:build_current_room_data).and_return({})

      result = execute_command('solve')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:puzzle)
    end

    it 'returns error without answer when no puzzle' do
      allow(DelvePuzzle).to receive(:first).and_return(nil)

      result = execute_command('solve')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no puzzle')
    end
  end

  describe 'dashboard edge cases' do
    let(:delve) { double('Delve', id: 1, name: 'Test Cave') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_hp: 3,
             max_hp: 6,
             willpower_dice: 0,
             time_remaining: 0.5,
               time_remaining_seconds: 30,
             current_level: 2,
             loot_collected: 100)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(delve_room).to receive(:respond_to?).and_return(false)
      allow(delve_room).to receive(:adjacent_room).and_return(nil)
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      allow(DelveTreasure).to receive(:first).and_return(nil)
      allow(DelvePuzzle).to receive(:first).and_return(nil)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(delve).to receive(:blocker_at).and_return(nil)
    end

    it 'shows low time remaining' do
      result = execute_command(nil)

      expect(result[:success]).to be true
      expect(result[:message]).to include('0:30')
    end

    it 'shows recover action when HP is low' do
      result = execute_command(nil)

      expect(result[:message]).to include('[recover]')
    end

    it 'shows current level' do
      result = execute_command(nil)

      expect(result[:message]).to include('Level 2')
    end
  end

  describe 'unknown subcommand' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
    end

    it 'returns error for invalid subcommand' do
      result = execute_command('invalid_command')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Unknown subcommand')
      expect(result[:message]).to include('invalid_command')
    end
  end

  describe 'exit and leave aliases' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'handles exit as flee alias' do
      flee_result = double('Result', success: true, message: 'You flee...', data: {})
      allow(DelveActionService).to receive(:flee!).and_return(flee_result)

      result = execute_command('exit')

      expect(result[:success]).to be true
    end

    it 'handles leave as flee alias' do
      flee_result = double('Result', success: true, message: 'You flee...', data: {})
      allow(DelveActionService).to receive(:flee!).and_return(flee_result)

      result = execute_command('leave')

      expect(result[:success]).to be true
    end
  end

  # ===== MORE EDGE CASE TESTS =====

  describe 'dashboard with blocked exits and stairs' do
    let(:delve) do
      double('Delve',
             id: 1,
             name: 'Dungeon',
             difficulty: 'normal',
             total_levels: 3)
    end
    let(:delve_room) { double('DelveRoom', id: 99, explored: true, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 0,
             time_remaining: 30,
               time_remaining_seconds: 1800,
             current_level: 1,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      allow(DelveTreasure).to receive(:first).and_return(nil)
      allow(DelvePuzzle).to receive(:first).and_return(nil)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(delve).to receive(:blocker_at).and_return(nil)
    end

    context 'when exit is blocked' do
      let(:north_blocker) { double('DelveBlocker', cleared?: false, stat_for_check: 'strength', effective_difficulty: 12) }

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:exit_blocked?).with('north').and_return(true)
        allow(delve_room).to receive(:exit_blocked?).with('east').and_return(false)
        allow(delve_room).to receive(:exit_blocked?).with('south').and_return(false)
        allow(delve_room).to receive(:exit_blocked?).with('west').and_return(false)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'north').and_return(north_blocker)
        allow(delve).to receive(:blocker_at).with(delve_room, 'east').and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'south').and_return(nil)
        allow(delve).to receive(:blocker_at).with(delve_room, 'west').and_return(nil)
      end

      it 'shows blocked direction' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('North - Blocked (strength DC 12)')
      end
    end

    context 'when room has stairs down' do
      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(true)
        allow(delve_room).to receive(:has_stairs_down?).and_return(true)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
      end

      it 'shows down direction with level info' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('[D] Down - Stairs to level 2')
      end
    end

    context 'when room has trap in direction' do
      let(:trap) { double('DelveTrap', description: 'Spike trap') }

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:adjacent_room).and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'north').and_return(trap)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'east').and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'south').and_return(nil)
        allow(DelveTrapService).to receive(:trap_in_direction).with(delve_room, 'west').and_return(nil)
      end

      it 'shows trap detected direction' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('North - Trap detected')
      end
    end

    context 'when adjacent room exists' do
      let(:adjacent) { double('DelveRoom', id: 100) }

      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:adjacent_room).with('north').and_return(adjacent)
        allow(delve_room).to receive(:adjacent_room).with('east').and_return(nil)
        allow(delve_room).to receive(:adjacent_room).with('south').and_return(nil)
        allow(delve_room).to receive(:adjacent_room).with('west').and_return(nil)
      end

      it 'shows clear direction' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        expect(result[:message]).to include('North - Clear')
      end
    end

    context 'when adjacent_room raises error' do
      before do
        allow(delve_room).to receive(:respond_to?).with(:exit_blocked?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:has_monster?).and_return(false)
        allow(delve_room).to receive(:respond_to?).with(:available_exits).and_return(true)
        allow(delve_room).to receive(:respond_to?).with(:has_stairs_down?).and_return(false)
        allow(delve_room).to receive(:adjacent_room).and_raise(StandardError.new('Room lookup failed'))
      end

      it 'handles error gracefully' do
        result = execute_command(nil)

        expect(result[:success]).to be true
        # Direction won't be shown if error occurs
        expect(result[:message]).to include('Dungeon')
      end
    end
  end

  describe 'listen with extended observation' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0,
             spend_time_seconds!: :ok)
    end
    let(:trap) { double('DelveTrap', id: 5, disabled?: false) }

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'extends observation across separate command instances via participant state' do
      state = nil
      allow(participant).to receive(:trap_observation_state) { state }
      allow(participant).to receive(:set_trap_observation_state!) do |_trap_id, start:, length:|
        state = { 'start' => start, 'length' => length }
      end
      allow(participant).to receive(:has_passed_trap?).and_return(false)
      allow(participant).to receive_messages(
        current_hp: 6,
        max_hp: 6,
        willpower_dice: 0,
        time_remaining: 10.0,
               time_remaining_seconds: 600,
        current_level: 1,
        loot_collected: 0
      )
      allow(delve).to receive(:tick_monster_movement!).and_return([])
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
      allow(DelveTrapService).to receive(:get_initial_sequence).and_return(
        start_point: 12,
        length: 5,
        formatted: '1 safe'
      )
      listen_result = double(
        'Result',
        success: true,
        message: 'You listen carefully...',
        data: { start_point: 12, length: 8 }
      )
      allow(DelveTrapService).to receive(:listen_more!).and_return(listen_result)

      described_class.new(character_instance).execute('listen n')
      described_class.new(character_instance).execute('listen n')

      expect(DelveTrapService).to have_received(:listen_more!).with(participant, trap, 12, 5)
    end

    context 'with disabled trap' do
      before do
        disabled_trap = double('DelveTrap', disabled?: true)
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(disabled_trap)
      end

      it 'returns error about disabled trap' do
        result = execute_command('listen n')

        expect(result[:success]).to be false
        expect(result[:message]).to include('disabled')
      end
    end
  end

  describe 'grab with no treasure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(DelveTreasure).to receive(:first).and_return(nil)
    end

    it 'returns error about no treasure' do
      result = execute_command('grab')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no treasure')
    end
  end

  describe 'fullmap subcommand' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelveMapService).to receive(:render_full_map).and_return({ tiles: [] })
    end

    it 'shows full explored map' do
      result = execute_command('fullmap')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Explored Map')
      expect(result[:data]).to have_key(:map)
    end
  end

  describe 'look subcommand failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'returns error when look fails' do
      look_result = double('Result', success: false, message: 'Room is too dark')
      allow(DelveMovementService).to receive(:look).and_return(look_result)

      result = execute_command('look')

      expect(result[:success]).to be false
      expect(result[:message]).to include('too dark')
    end
  end

  describe 'enter with default name' do
    let(:delve) do
      instance_double(Delve, id: 1, name: 'Mysterious Dungeon', destroy: true, start!: true, update: true)
    end
    let(:entrance_room) { double('DelveRoom', id: 99, update: true, room_id: nil, has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:new_participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: entrance_room,
             time_remaining: 60,
               time_remaining_seconds: 3600,
             update: true,
             current_level: 1,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:look_result) do
      double('Result', success: true, message: 'A mysterious chamber...', data: {})
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: nil)))
      )
      allow(Delve).to receive(:create).and_return(delve)
      allow(DelveGeneratorService).to receive(:generate_level!)
      allow(delve).to receive(:entrance_room).and_return(entrance_room)
      allow(DelveParticipant).to receive(:create).and_return(new_participant)
      allow(DelveMovementService).to receive(:look).and_return(look_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})
    end

    it 'uses default name when no name provided' do
      expect(Delve).to receive(:create).with(hash_including(name: 'Mysterious Dungeon'))

      execute_command('enter')
    end

    it 'uses default name for whitespace-only input' do
      expect(Delve).to receive(:create).with(hash_including(name: 'Mysterious Dungeon'))

      execute_command('enter    ')
    end
  end

  describe 'move failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'returns error when move fails' do
      move_result = double('Result', success: false, message: 'Cannot move that direction', data: nil)
      allow(DelveMovementService).to receive(:move!).and_return(move_result)

      result = execute_command('north')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Cannot move')
    end
  end

  describe 'descend failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'returns error when descend fails' do
      descend_result = double('Result', success: false, message: 'No stairs here')
      allow(DelveMovementService).to receive(:descend!).and_return(descend_result)

      result = execute_command('down')

      expect(result[:success]).to be false
      expect(result[:message]).to include('No stairs')
    end
  end

  describe 'fight failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             character_instance: character_instance,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(FightService).to receive(:find_active_fight).and_return(nil)
    end

    it 'returns error when no monster present' do
      allow(delve).to receive(:monsters_in_room).with(delve_room).and_return([])
      allow(delve_room).to receive(:has_monster?).and_return(false)

      result = execute_command('fight')

      expect(result[:success]).to be false
      expect(result[:message]).to include('nothing to fight')
    end
  end

  describe 'status failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
    end

    it 'returns error when status fails' do
      status_result = double('Result', success: false, message: 'Status unavailable')
      allow(DelveActionService).to receive(:status).and_return(status_result)

      result = execute_command('status')

      expect(result[:success]).to be false
      expect(result[:message]).to include('unavailable')
    end
  end

  describe 'flee failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
    end

    it 'returns error when flee fails' do
      flee_result = double('Result', success: false, message: 'Cannot flee during combat')
      allow(DelveActionService).to receive(:flee!).and_return(flee_result)

      result = execute_command('flee')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Cannot flee')
    end
  end

  describe 'recover failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'returns error when recover fails' do
      recover_result = double('Result', success: false, message: 'Already at full health')
      allow(DelveActionService).to receive(:recover!).and_return(recover_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})

      result = execute_command('recover')

      expect(result[:success]).to be false
      expect(result[:message]).to include('full health')
    end
  end

  describe 'focus failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
    end

    it 'returns error when focus fails' do
      focus_result = double('Result', success: false, message: 'Too distracted')
      allow(DelveActionService).to receive(:focus!).and_return(focus_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})

      result = execute_command('focus')

      expect(result[:success]).to be false
      expect(result[:message]).to include('distracted')
    end
  end

  describe 'easier failure' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:blocker) { double('DelveBlocker', cleared?: false) }

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(delve).to receive(:blocker_at).and_return(blocker)
    end

    it 'returns error when easier fails' do
      easier_result = double('Result', success: false, message: 'Cannot weaken further')
      allow(DelveSkillCheckService).to receive(:make_easier!).and_return(easier_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})

      result = execute_command('easier n')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Cannot weaken')
    end
  end

  describe 'solve with answer' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0)
    end
    let(:puzzle) { double('DelvePuzzle', solved?: false) }

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(DelvePuzzle).to receive(:first).and_return(puzzle)
      allow(delve).to receive(:tick_monster_movement!).and_return([])
    end

    it 'attempts puzzle with provided answer' do
      solve_result = double('Result', success: true, message: 'Correct!', data: { reward: 50 })
      allow(DelvePuzzleService).to receive(:attempt!).and_return(solve_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})

      result = execute_command('solve ANSWER')

      expect(DelvePuzzleService).to have_received(:attempt!).with(participant, puzzle, 'ANSWER')
      expect(result[:success]).to be true
    end

    it 'handles failed solve attempt as success with failure message' do
      solve_result = double('Result', success: false, message: 'Wrong answer', data: { solved: false })
      allow(DelvePuzzleService).to receive(:attempt!).and_return(solve_result)
      allow(DelveMapService).to receive(:render_minimap).and_return({})

      result = execute_command('solve wrong')

      # Puzzle solve attempts always return success so the message
      # appears in game output without "Error:" prefix
      expect(result[:success]).to be true
      expect(result[:message]).to include('Wrong answer')
    end
  end

  describe 'contextual alias subcommand routing' do
    let(:delve) { double('Delve', id: 1, name: 'Test Dungeon') }
    let(:delve_room) { double('DelveRoom', id: 99, available_exits: [], has_stairs_down?: false, has_monster?: false, exit_blocked?: false) }
    let(:participant) do
      double('DelveParticipant',
             id: 1,
             delve: delve,
             current_room: delve_room,
             reload: nil,
             current_level: 1,
             time_remaining: 15.5,
               time_remaining_seconds: 930,
             current_hp: 6,
             max_hp: 6,
             willpower_dice: 2,
             loot_collected: 0,
             extracted?: false,
             dead?: false,
             active?: true,
             character_instance: nil)
    end
    let(:blocker) { double('DelveBlocker', cleared?: false) }

    before do
      allow(DelveParticipant).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', eager: double('Dataset', first: participant)))
      )
      allow(participant).to receive(:reload).and_return(participant)
      allow(delve).to receive(:blocker_at).and_return(blocker)
    end

    it 'routes "cross e" contextual alias to handle_cross, not handle_move' do
      # When player types "cross e", command_word='cross' and text='e'
      # This should call handle_cross('e'), NOT handle_move('east')
      cross_result = double('Result', success: true, message: 'You cross the obstacle!', data: {})
      allow(DelveSkillCheckService).to receive(:attempt!).and_return(cross_result)
      allow(DelveSkillCheckService).to receive(:party_bonus).and_return(0)
      allow(delve).to receive(:tick_monster_movement!).and_return([])
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(participant).to receive_messages(
        current_hp: 6, max_hp: 6, willpower_dice: 0, time_remaining: 10.0,
               time_remaining_seconds: 600,
        current_level: 1
      )
      allow(delve).to receive(:total_levels).and_return(3)

      result = command.execute('cross e')

      expect(DelveSkillCheckService).to have_received(:attempt!).with(
        participant,
        blocker,
        hash_including(use_willpower: false, party_bonus: 0)
      )
      expect(result[:message]).not_to include('Unknown subcommand')
    end

    it 'routes "easier e" contextual alias to handle_easier, not handle_move' do
      # When player types "easier e", command_word='easier' and text='e'
      easier_result = double('Result', success: false, message: 'Cannot weaken further')
      allow(DelveSkillCheckService).to receive(:make_easier!).and_return(easier_result)

      result = command.execute('easier e')

      expect(DelveSkillCheckService).to have_received(:make_easier!).with(participant, blocker)
      expect(result[:success]).to be false
      expect(result[:message]).to include('Cannot weaken')
    end

    it 'routes "study e" contextual alias to handle_study, not handle_move' do
      # When player types "study e", command_word='study' and text='e'
      allow(delve).to receive(:blocker_at).and_return(blocker)
      allow(blocker).to receive_messages(
        blocker_type: 'heavy_object',
        direction: 'east',
        dc: 12,
        adjusted_dc: 10,
        times_weakened: 1,
        verb: 'push',
        cleared?: false,
        stat_for_check: 'strength',
        effective_difficulty: 10,
        description: 'A heavy boulder blocks the path.',
        easier_attempts: 1
      )
      allow(DelveMapService).to receive(:render_minimap).and_return({})
      allow(participant).to receive_messages(
        current_hp: 6, max_hp: 6, willpower_dice: 0, time_remaining: 10.0,
               time_remaining_seconds: 600,
        current_level: 1
      )
      allow(delve).to receive(:total_levels).and_return(3)

      result = command.execute('study e')

      expect(result[:success]).to be true
      expect(result[:message]).not_to include('Unknown subcommand')
    end
  end

  describe 'real room integration' do
    before do
      RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
        t.name = 'Delve Room'
        t.category = 'delve'
        t.room_type = 'dungeon'
        t.short_description = 'A dark dungeon chamber.'
        t.width = 30
        t.length = 30
        t.height = 10
        t.active = true
        t.universe_id = universe.id
      end
    end

    it 'sets character current_room to the entrance real Room on enter' do
      execute_command('enter Test Dungeon')

      character_instance.reload
      participant = DelveParticipant.first(character_instance_id: character_instance.id, status: 'active')
      entrance_delve_room = participant.delve.entrance_room(1)

      expect(entrance_delve_room.room_id).not_to be_nil
      expect(character_instance.current_room_id).to eq(entrance_delve_room.room_id)
    end

    it 'stores pre_delve_room_id on the participant' do
      original_room_id = character_instance.current_room_id
      execute_command('enter Test Dungeon')

      participant = DelveParticipant.first(character_instance_id: character_instance.id, status: 'active')
      expect(participant.pre_delve_room_id).to eq(original_room_id)
    end

    it 'returns character to pre-delve room on flee' do
      original_room_id = character_instance.current_room_id
      execute_command('enter Test Dungeon')

      # Need to reset participant lookup for the flee command
      @participant = nil
      execute_command('flee')

      character_instance.reload
      expect(character_instance.current_room_id).to eq(original_room_id)
    end
  end

end
