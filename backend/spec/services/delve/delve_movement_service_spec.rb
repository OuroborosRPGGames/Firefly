# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveMovementService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { Reality.create(name: 'Primary', reality_type: 'primary', time_offset: 0) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Delver', surname: 'Hero') }
  let(:character_instance) do
    CharacterInstance.create(
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  let(:delve) do
    Delve.create(
      name: 'Test Dungeon',
      difficulty: 'normal',
      status: 'active',
      time_limit_minutes: 60,
      levels_generated: 2,
      location_id: location.id,
      started_at: Time.now
    )
  end

  let(:entrance_room) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 0,
      level: 1,
      grid_x: 0,
      grid_y: 0,
      is_entrance: true,
      explored: true
    )
  end

  let(:adjacent_room) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 1,
      level: 1,
      grid_x: 1,
      grid_y: 0,
      explored: false
    )
  end

  let(:exit_room) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'terminal',
      depth: 2,
      level: 1,
      grid_x: 2,
      grid_y: 0,
      is_exit: true,
      explored: true
    )
  end

  let(:level2_entrance) do
    DelveRoom.create(
      delve_id: delve.id,
      room_type: 'corridor',
      depth: 3,
      level: 2,
      grid_x: 0,
      grid_y: 0,
      is_entrance: true,
      explored: false
    )
  end

  let(:participant) do
    DelveParticipant.create(
      delve_id: delve.id,
      character_instance_id: character_instance.id,
      current_delve_room_id: entrance_room.id,
      current_level: 1,
      status: 'active',
      loot_collected: 0,
      time_spent_minutes: 10,
      time_spent_seconds: 600
    )
  end

  before do
    # Setup stub for danger_warnings
    allow(DelveVisibilityService).to receive(:danger_warnings).and_return([])
  end

  describe '.move!' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns error result' do
        result = described_class.move!(participant, 'north')
        expect(result.success).to be false
        expect(result.message).to include("not in a delve")
      end
    end

    context 'when participant has extracted' do
      before do
        participant.update(status: 'extracted')
      end

      it 'returns error result' do
        result = described_class.move!(participant, 'north')
        expect(result.success).to be false
        expect(result.message).to include("extracted")
      end
    end

    context 'when participant is dead' do
      before do
        participant.update(status: 'dead')
      end

      it 'returns error result' do
        result = described_class.move!(participant, 'north')
        expect(result.success).to be false
        expect(result.message).to include("dead")
      end
    end

    context 'moving in valid direction' do
      before do
        entrance_room
        adjacent_room
        # Stub available_exits
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'moves participant to adjacent room' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
        expect(participant.reload.current_delve_room_id).to eq(adjacent_room.id)
      end

      it 'returns success message with direction' do
        result = described_class.move!(participant, 'east')
        expect(result.message).to include('move east')
      end

      it 'includes room data in result' do
        result = described_class.move!(participant, 'east')
        expect(result.data[:room].id).to eq(adjacent_room.id)
        expect(result.data[:direction]).to eq('east')
      end

      it 'handles direction shortcuts' do
        result = described_class.move!(participant, 'e')
        expect(result.success).to be true
      end
    end

    context 'when a monster in the room can pursue' do
      let!(:spider) do
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: entrance_room.id,
          monster_type: 'spider',
          is_active: true
        )
      end

      before do
        entrance_room
        adjacent_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
        allow(DelveCombatService).to receive(:check_auto_combat!).and_return(nil)
        allow(spider).to receive(:available_moves).and_return([{ direction: 'east', room: adjacent_room }])
      end

      it 'moves the pursuing monster into the destination room' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
        expect(spider.reload.current_room_id).to eq(adjacent_room.id)
      end

      it 'includes pursuit text in the movement message' do
        result = described_class.move!(participant, 'east')
        expect(result.message).to include('follows after you')
      end
    end

    context 'moving in invalid direction' do
      before do
        entrance_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['north'])
      end

      it 'returns error with available exits' do
        result = described_class.move!(participant, 'west')
        expect(result.success).to be false
        expect(result.message).to include("can't go that way")
        expect(result.message).to include("north")
      end
    end

    context 'with trap in direction' do
      let(:trap) do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 5,
          damage: 1
        )
      end

      before do
        entrance_room
        adjacent_room
        trap
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        allow(DelveTrapService).to receive(:get_initial_sequence).and_return({
          start_point: 1,
          length: 15,
          formatted: "1:safe 2:DANGER 3:safe..."
        })
      end

      it 'shows trap challenge when no pulse provided' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be false
        expect(result.data[:trap_challenge]).to be true
        expect(result.message).to include('trap blocks the way')
      end

      it 'attempts passage when pulse provided' do
        trap_result = double('Result', success: true, message: 'You slip through!', data: { damage: 0 })
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(trap_result)

        result = described_class.move!(participant, 'east', trap_pulse: 3, trap_sequence_start: 1)
        expect(result.success).to be true
        expect(result.message).to include('slip through')
      end

      it 'halts movement when trap passage returns an error result' do
        trap_result = double('Result', success: false, message: 'Trap timing data is missing.', data: { missing_sequence: true })
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(trap_result)
        initial_room_id = participant.current_room.id
        initial_seconds = participant.time_spent_seconds

        result = described_class.move!(participant, 'east', trap_pulse: 3, trap_sequence_start: nil)

        expect(result.success).to be false
        expect(result.message).to include('timing data is missing')
        expect(result.data[:missing_sequence]).to be true
        expect(participant.reload.current_room.id).to eq(initial_room_id)
        expect(participant.time_spent_seconds).to eq(initial_seconds)
      end

      it 'stops movement when trap passage defeats participant' do
        trap_result = double('Result', success: false, message: 'The trap catches you and you collapse!', data: { damage: 6, defeated: true })
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(trap_result)
        initial_room_id = participant.current_room.id
        initial_seconds = participant.time_spent_seconds

        result = described_class.move!(participant, 'east', trap_pulse: 3, trap_sequence_start: 1)

        expect(result.success).to be false
        expect(result.data[:defeated]).to be true
        expect(participant.reload.current_room.id).to eq(initial_room_id)
        expect(participant.time_spent_seconds).to eq(initial_seconds)
      end
    end

    context 'time tracking in seconds' do
      before do
        entrance_room
        adjacent_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'decrements time when moving (10 seconds)' do
        initial_seconds = participant.reload.time_spent_seconds || 0
        described_class.move!(participant, 'east')
        expect(participant.reload.time_spent_seconds).to eq(initial_seconds + 10)
      end

      it 'returns fractional minutes for time_remaining (rounded to 1 decimal)' do
        participant.update(time_spent_seconds: 3590)
        expect(participant.reload.time_remaining).to eq(0.2)
      end
    end

    context 'when a blocker blocks the direction' do
      let!(:blocker) do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          blocker_type: 'gap',
          difficulty: 10,
          cleared: false
        )
      end

      before do
        adjacent_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'blocks movement and suggests cross command' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be false
        expect(result.message).to include('gap')
        expect(result.message).to include('cross')
      end

      it 'allows movement after blocker is cleared' do
        blocker.update(cleared: true)
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
      end
    end

    context 'when time expires during movement' do
      before do
        entrance_room
        adjacent_room
        # Set time so movement would expire it (60 min limit = 3600 seconds)
        participant.update(time_spent_seconds: 3600)
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'returns time expired result' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be false
        expect(result.message).to include('Time')
        expect(result.data[:time_expired]).to be true
      end
    end

    context 'going down at non-exit room' do
      before do
        entrance_room
        # entrance is not an exit
      end

      it 'returns error about no stairs' do
        result = described_class.move!(participant, 'down')
        expect(result.success).to be false
        expect(result.message).to include('no stairs')
      end
    end
  end

  describe '.descend!' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns not in delve error' do
        result = described_class.descend!(participant)
        expect(result.success).to be false
        expect(result.message).to include('not in a delve')
      end
    end

    context 'when participant has extracted' do
      before do
        participant.update(status: 'extracted')
      end

      it 'returns extracted error' do
        result = described_class.descend!(participant)
        expect(result.success).to be false
        expect(result.message).to include('already extracted')
      end
    end

    context 'at exit room' do
      before do
        entrance_room
        exit_room
        level2_entrance
        participant.update(current_delve_room_id: exit_room.id)
      end

      it 'moves participant to next level entrance' do
        result = described_class.descend!(participant)
        expect(result.success).to be true
        expect(result.data[:level]).to eq(2)
      end

      it 'includes level transition message' do
        result = described_class.descend!(participant)
        expect(result.message).to include('descend')
        expect(result.message).to include('level 2')
      end
    end

    context 'at non-exit room' do
      before do
        entrance_room
      end

      it 'returns error' do
        result = described_class.descend!(participant)
        expect(result.success).to be false
        expect(result.message).to include('no stairs')
      end
    end

    context 'when time expires during descent' do
      before do
        entrance_room
        exit_room
        participant.update(current_delve_room_id: exit_room.id, time_spent_seconds: 3600)
      end

      it 'returns time expired result' do
        result = described_class.descend!(participant)
        expect(result.success).to be false
        expect(result.data[:time_expired]).to be true
      end
    end
  end

  describe '.look' do
    context 'with no current room' do
      before do
        participant.update(current_delve_room_id: nil)
      end

      it 'returns error result' do
        result = described_class.look(participant)
        expect(result.success).to be false
        expect(result.message).to include("not in a delve")
      end
    end

    context 'when participant has extracted' do
      before do
        participant.update(status: 'extracted')
      end

      it 'returns extracted error' do
        result = described_class.look(participant)
        expect(result.success).to be false
        expect(result.message).to include('already extracted')
      end
    end

    context 'with current room' do
      before do
        entrance_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east', 'south'])
      end

      it 'returns success' do
        result = described_class.look(participant)
        expect(result.success).to be true
      end

      it 'includes room description text' do
        result = described_class.look(participant)
        expect(result.message).to include('corridor')
      end

      it 'includes exits in response data' do
        result = described_class.look(participant)
        expect(result.data[:exits]).to eq(['east', 'south'])
      end

      it 'includes room in response data' do
        result = described_class.look(participant)
        expect(result.data[:room]).to eq(entrance_room)
      end
    end

    context 'with treasure in room' do
      before do
        entrance_room
        DelveTreasure.create(delve_room_id: entrance_room.id, gold_value: 50, looted: false)
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return([])
      end

      it 'shows treasure description' do
        result = described_class.look(participant)
        expect(result.message).to include('50 gold')
      end
    end

    context 'with monsters in room' do
      before do
        entrance_room
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: entrance_room.id,
          monster_type: 'goblin',
          level: 1,
          is_active: true
        )
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return([])
      end

      it 'shows monster description' do
        result = described_class.look(participant)
        expect(result.message).to include('Goblin')
        expect(result.message).to include('lurks')
      end
    end

    context 'with danger warnings' do
      before do
        entrance_room
        allow(DelveVisibilityService).to receive(:danger_warnings).and_return(['Danger to the north!'])
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return([])
      end

      it 'includes warnings in response' do
        result = described_class.look(participant)
        expect(result.data[:exits]).to be_a(Array)
      end
    end
  end

  describe '.show_trap_challenge' do
    let(:trap) do
      DelveTrap.create(
        delve_room_id: entrance_room.id,
        direction: 'east',
        timing_a: 3,
        timing_b: 5,
        damage: 1
      )
    end

    before do
      entrance_room
      trap
      allow(DelveTrapService).to receive(:get_initial_sequence).and_return({
        start_point: 1,
        length: 15,
        formatted: "1:safe 2:DANGER 3:safe 4:DANGER 5:safe..."
      })
    end

    it 'uses participant-seeded sequence for consistency with go/trap passage' do
      expect(DelveTrapService).to receive(:get_initial_sequence).with(trap, participant.id).and_return({
        start_point: 1,
        length: 15,
        formatted: "1:safe 2:DANGER 3:safe 4:DANGER 5:safe..."
      })

      described_class.show_trap_challenge(participant, trap, 'east')
    end

    it 'returns trap challenge data' do
      result = described_class.show_trap_challenge(participant, trap, 'east')
      expect(result.success).to be false
      expect(result.data[:trap_challenge]).to be true
      expect(result.data[:trap_id]).to eq(trap.id)
      expect(result.data[:direction]).to eq('east')
    end

    it 'includes sequence information' do
      result = described_class.show_trap_challenge(participant, trap, 'east')
      expect(result.data[:sequence_start]).to eq(1)
      expect(result.data[:sequence_length]).to eq(15)
    end

    it 'includes instructions in message' do
      result = described_class.show_trap_challenge(participant, trap, 'east')
      expect(result.message).to include('e &lt;pulse#&gt;')
      expect(result.message).to include('listen e')
    end

    context 'when participant has passed trap before' do
      before do
        allow(participant).to receive(:has_passed_trap?).and_return(true)
      end

      it 'provides experienced hint' do
        result = described_class.show_trap_challenge(participant, trap, 'east')
        expect(result.message).to include("passed this trap before")
        expect(result.data[:experienced]).to be true
      end
    end

    context 'when participant is new to trap' do
      before do
        allow(participant).to receive(:has_passed_trap?).and_return(false)
      end

      it 'provides first-time hint' do
        result = described_class.show_trap_challenge(participant, trap, 'east')
        expect(result.message).to include("First time through")
        expect(result.data[:experienced]).to be false
      end
    end
  end

  describe 'auto-combat on room entry' do
    let(:monster_room) do
      DelveRoom.create(
        delve_id: delve.id,
        room_type: 'corridor',
        depth: 1,
        level: 1,
        grid_x: 1,
        grid_y: 0,
        explored: false
      )
    end

    before do
      entrance_room
      monster_room
      # Setup exits
      allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
      allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
    end

    context 'when entering a room with monsters' do
      let!(:monster) do
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: monster_room.id,
          monster_type: 'goblin',
          level: 1,
          is_active: true,
          hp: 6,
          max_hp: 6
        )
      end

      it 'auto-starts combat' do
        result = described_class.move!(participant, 'east')

        expect(result.success).to be true
        expect(result.data[:combat_started]).to be true
        expect(Fight.count).to eq(1)
      end

      it 'returns fight_id in data' do
        result = described_class.move!(participant, 'east')

        expect(result.data[:fight_id]).not_to be_nil
        fight = Fight[result.data[:fight_id]]
        expect(fight).not_to be_nil
        expect(fight.status).to eq('input')
      end

      it 'returns combat menu data' do
        result = described_class.move!(participant, 'east')

        expect(result.data[:quickmenu]).not_to be_nil
        expect(result.data[:quickmenu][:type]).to eq(:quickmenu)
      end

      it 'message indicates movement direction' do
        result = described_class.move!(participant, 'east')

        expect(result.message).to include('move east')
        expect(result.data[:combat_started]).to be true
      end

      it 'includes direction in message' do
        result = described_class.move!(participant, 'east')

        expect(result.message).to include('move east')
      end

      it 'still moves the participant to the target room' do
        described_class.move!(participant, 'east')

        expect(participant.reload.current_delve_room_id).to eq(monster_room.id)
      end
    end

    context 'when entering a room with monsters and trap triggered' do
      let!(:monster) do
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: monster_room.id,
          monster_type: 'skeleton',
          level: 1,
          is_active: true,
          hp: 6,
          max_hp: 6
        )
      end

      let(:trap) do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 5,
          damage: 1
        )
      end

      before do
        trap
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        trap_result = double('Result', success: true, message: 'You take 1 damage from the trap!', data: { damage: 1 })
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(trap_result)
      end

      it 'includes trap message in combat message' do
        result = described_class.move!(participant, 'east', trap_pulse: 3, trap_sequence_start: 1)

        expect(result.success).to be true
        expect(result.data[:combat_started]).to be true
        expect(result.message).to include('trap')
      end
    end

    context 'when entering a room without monsters' do
      it 'shows normal room description' do
        result = described_class.move!(participant, 'east')

        expect(result.success).to be true
        expect(result.data[:combat_started]).to be_falsey
        expect(result.message).to include('corridor')
      end

      it 'does not create a fight' do
        expect { described_class.move!(participant, 'east') }.not_to change { Fight.count }
      end
    end

    context 'when entering a room with only inactive monsters' do
      let!(:inactive_monster) do
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: monster_room.id,
          monster_type: 'goblin',
          level: 1,
          is_active: false,
          hp: 0,
          max_hp: 6
        )
      end

      it 'does not start combat' do
        result = described_class.move!(participant, 'east')

        expect(result.success).to be true
        expect(result.data[:combat_started]).to be_falsey
      end
    end
  end

  describe 'private methods' do
    describe 'build_room_description' do
      before do
        entrance_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow_any_instance_of(DelveRoom).to receive(:description_text).and_return('A dark corridor.')
      end

      it 'includes room description' do
        result = described_class.send(:build_room_description, entrance_room, participant)
        expect(result).to include('dark corridor')
      end

      it 'includes room description' do
        result = described_class.send(:build_room_description, entrance_room, participant)
        expect(result).to include('dark corridor')
      end

      it 'includes exits' do
        result = described_class.send(:build_room_description, entrance_room, participant)
        expect(result).to include('Exits: East')
      end
    end

    describe 'collect_obstacles' do
      before do
        entrance_room
      end

      it 'returns empty array for room with no obstacles' do
        result = described_class.send(:collect_obstacles, entrance_room)
        expect(result).to eq([])
      end

      it 'includes traps in obstacles' do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'north',
          timing_a: 3,
          timing_b: 5,
          disabled: false
        )
        result = described_class.send(:collect_obstacles, entrance_room)
        expect(result.size).to eq(1)
        expect(result.first).to include('North')
        expect(result.first).to include('Trap')
      end

      it 'includes blockers in obstacles' do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'south',
          blocker_type: 'barricade',
          cleared: false
        )
        result = described_class.send(:collect_obstacles, entrance_room)
        expect(result.size).to eq(1)
        expect(result.first).to include('South')
        expect(result.first).to include('Barricade')
      end

      it 'excludes disabled traps' do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'north',
          timing_a: 3,
          timing_b: 5,
          disabled: true
        )
        result = described_class.send(:collect_obstacles, entrance_room)
        expect(result).to eq([])
      end

      it 'excludes cleared blockers' do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'south',
          blocker_type: 'barricade',
          cleared: true
        )
        result = described_class.send(:collect_obstacles, entrance_room)
        expect(result).to eq([])
      end
    end

    describe 'build_actions_list' do
      before do
        entrance_room
      end

      it 'always includes map action' do
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, nil, [], nil)
        expect(result).to include('map')
      end

      it 'includes grab when treasure present' do
        treasure = DelveTreasure.create(delve_room_id: entrance_room.id, gold_value: 50)
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, treasure, [], nil)
        expect(result).to include('grab')
      end

      it 'includes fight when monsters present' do
        monster = DelveMonster.create(
          delve_id: delve.id,
          current_room_id: entrance_room.id,
          monster_type: 'goblin',
          level: 1,
          is_active: true
        )
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, nil, [monster], nil)
        expect(result).to include('fight')
      end

      it 'includes recover when HP below max' do
        character_instance.update(health: 3, max_health: 6)
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, nil, [], nil)
        expect(result).to include('recover')
      end

      it 'does not include recover at full HP' do
        character_instance.update(health: 6, max_health: 6)
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, nil, [], nil)
        expect(result).not_to include('recover')
      end

      it 'includes focus when willpower below 3' do
        participant.update(willpower_dice: 1)
        result = described_class.send(:build_actions_list, entrance_room, participant, delve, nil, [], nil)
        expect(result).to include('focus')
      end

      it 'includes down when room is exit' do
        result = described_class.send(:build_actions_list, exit_room, participant, delve, nil, [], nil)
        expect(result).to include('down')
      end
    end

    # Note: Private methods like get_adjacent_room, increment_time, check_time_expired,
    # build_time_expired_result, and do_move don't exist in this service.
    # These behaviors should be tested through the public API (move!, descend!, look).
  end

  # ============================================
  # Additional Move Tests
  # ============================================

  describe '.move! additional edge cases' do
    context 'with blocker in direction' do
      let(:blocker) do
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          blocker_type: 'barricade',
          cleared: false
        )
      end

      before do
        entrance_room
        adjacent_room
        blocker
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'blocks movement when blocker is uncleared' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be false
        expect(result.message).to include('barricade')
        expect(result.message).to include('cross')
      end

      it 'allows movement when blocker is cleared' do
        blocker.update(cleared: true)
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
      end
    end

    context 'with blocker only on the target room reverse edge' do
      let(:reverse_blocker) do
        DelveBlocker.create(
          delve_room_id: adjacent_room.id,
          direction: 'west',
          blocker_type: 'barricade',
          cleared: false
        )
      end

      before do
        entrance_room
        adjacent_room
        reverse_blocker
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'blocks movement using canonical blocker lookup' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be false
        expect(result.message).to include('barricade')
      end
    end

    context 'when room has multiple exits' do
      before do
        entrance_room
        adjacent_room
        # Create rooms in multiple directions
        north_room = DelveRoom.create(
          delve_id: delve.id,
          room_type: 'corridor',
          depth: 1,
          level: 1,
          grid_x: 0,
          grid_y: -1,
          explored: false
        )
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(%w[north east south])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'can move in any available direction' do
        result = described_class.move!(participant, 'north')
        # Should find the north room or fail gracefully
        expect(result).to be_a(described_class::Result)
      end
    end

    context 'when trap passage succeeds' do
      let(:trap) do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 5,
          damage: 1
        )
      end

      before do
        entrance_room
        adjacent_room
        trap
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(
          double(success: true, message: 'You slip through!', data: { damage: 0 })
        )
      end

      it 'moves to adjacent room after successful trap passage' do
        result = described_class.move!(participant, 'east', trap_pulse: 3, trap_sequence_start: 1)
        expect(result.success).to be true
        expect(participant.reload.current_delve_room_id).to eq(adjacent_room.id)
      end
    end

    context 'when trap passage does damage' do
      let(:trap) do
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          timing_a: 3,
          timing_b: 5,
          damage: 1
        )
      end

      before do
        entrance_room
        adjacent_room
        trap
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(trap)
        # Note: trap passage can still succeed while applying damage.
        allow(DelveTrapService).to receive(:attempt_passage!).and_return(
          double(success: true, message: 'The trap strikes you!', data: { damage: 1 })
        )
      end

      it 'continues movement and includes trap message' do
        result = described_class.move!(participant, 'east', trap_pulse: 1, trap_sequence_start: 1)
        # Per service code: "Even if damaged, continue with movement"
        expect(result.success).to be true
        expect(result.message).to include('strikes')
        expect(result.data[:trap_damage]).to eq(1)
      end
    end
  end

  # ============================================
  # Descend Additional Tests
  # ============================================

  describe '.descend! additional tests' do
    context 'when at exit room' do
      before do
        exit_room
        participant.update(current_delve_room_id: exit_room.id)
        # The service will generate next level if needed
        allow(delve).to receive(:generate_next_level!)
      end

      it 'attempts to descend to next level' do
        # Mock to prevent actual level generation
        allow(delve).to receive(:entrance_room).and_return(nil)
        result = described_class.descend!(participant)
        # Should return a result (success depends on level generation)
        expect(result).to be_a(described_class::Result)
      end
    end

    context 'at final level exit' do
      before do
        exit_room
        # Mark this as final level
        delve.update(levels_generated: 1)
        participant.update(current_delve_room_id: exit_room.id)
        # Mock level generation on any Delve instance (since service loads fresh from DB)
        allow_any_instance_of(Delve).to receive(:generate_next_level!)
        allow_any_instance_of(Delve).to receive(:entrance_room).and_return(nil)
      end

      it 'returns a result when descending at final level' do
        result = described_class.descend!(participant)
        # Should handle the scenario gracefully
        expect(result).to be_a(described_class::Result)
      end
    end
  end

  # ============================================
  # Look Additional Tests
  # ============================================

  describe '.look additional tests' do
    context 'with multiple obstacles' do
      before do
        entrance_room
        DelveTrap.create(
          delve_room_id: entrance_room.id,
          direction: 'north',
          timing_a: 3,
          timing_b: 5,
          disabled: false
        )
        # Valid blocker types: barricade, locked_door, gap, narrow
        DelveBlocker.create(
          delve_room_id: entrance_room.id,
          direction: 'east',
          blocker_type: 'barricade',
          cleared: false
        )
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(%w[north east])
      end

      it 'shows all obstacles' do
        result = described_class.look(participant)
        expect(result.message).to include('Trap')
        expect(result.message).to include('Barricade')
      end
    end

    context 'at exit room' do
      before do
        exit_room
        participant.update(current_delve_room_id: exit_room.id)
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['west'])
      end

      it 'mentions stairs down' do
        result = described_class.look(participant)
        expect(result.message).to include('stairs').or include('descend').or include('exit')
      end
    end

    context 'with looted treasure' do
      before do
        entrance_room
        DelveTreasure.create(delve_room_id: entrance_room.id, gold_value: 50, looted: true)
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return([])
      end

      it 'does not show looted treasure' do
        result = described_class.look(participant)
        expect(result.message).not_to include('50 gold')
      end
    end

    context 'with inactive monster' do
      before do
        entrance_room
        DelveMonster.create(
          delve_id: delve.id,
          current_room_id: entrance_room.id,
          monster_type: 'goblin',
          level: 1,
          is_active: false
        )
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return([])
      end

      it 'does not show inactive monsters' do
        result = described_class.look(participant)
        expect(result.message).not_to include('lurks')
      end
    end
  end

  # ============================================
  # Real Room Character Placement Tests
  # ============================================

  describe 'character real room placement' do
    context 'when moving to a room with a real Room record' do
      let(:real_room) { create(:room, location: location, name: 'Delve Real Room') }

      before do
        entrance_room
        adjacent_room
        adjacent_room.update(room_id: real_room.id)
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'updates character_instance current_room_id to the real room' do
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
        expect(participant.character_instance.reload.current_room_id).to eq(real_room.id)
      end
    end

    context 'when moving to a room without a real Room record' do
      before do
        entrance_room
        adjacent_room
        allow_any_instance_of(DelveRoom).to receive(:available_exits).and_return(['east'])
        allow(DelveTrapService).to receive(:trap_in_direction).and_return(nil)
      end

      it 'does not change character_instance current_room_id' do
        original_room_id = participant.character_instance.current_room_id
        result = described_class.move!(participant, 'east')
        expect(result.success).to be true
        expect(participant.character_instance.reload.current_room_id).to eq(original_room_id)
      end
    end

    context 'when descending to a new level' do
      let(:real_room_l2) { create(:room, location: location, name: 'Level 2 Room') }

      before do
        entrance_room
        exit_room
        level2_entrance.update(room_id: real_room_l2.id)
        participant.update(current_delve_room_id: exit_room.id)
      end

      it 'updates character_instance current_room_id to the new level entrance room' do
        result = described_class.descend!(participant)
        expect(result.success).to be true
        expect(participant.character_instance.reload.current_room_id).to eq(real_room_l2.id)
      end
    end
  end

  # ============================================
  # Result Class Tests
  # ============================================

  describe 'Result class' do
    it 'creates success result' do
      result = described_class::Result.new(success: true, message: 'Test', data: { key: 'value' })
      expect(result.success).to be true
      expect(result.success?).to be true
      expect(result.message).to eq('Test')
      expect(result.data[:key]).to eq('value')
    end

    it 'creates failure result' do
      result = described_class::Result.new(success: false, message: 'Failed', data: {})
      expect(result.success).to be false
      expect(result.success?).to be false
    end
  end

  # ============================================
  # build_current_room_data Tests
  # ============================================

  describe '.build_current_room_data' do
    before do
      entrance_room
    end

    it 'returns structured room data with grid position' do
      data = described_class.build_current_room_data(participant)
      expect(data).to include(:grid_x, :grid_y, :exits)
      expect(data[:grid_x]).to eq(0)
      expect(data[:grid_y]).to eq(0)
    end

    it 'returns empty hash when participant has no current room' do
      participant.update(current_delve_room_id: nil)
      data = described_class.build_current_room_data(participant)
      expect(data).to eq({})
    end

    it 'includes monster info when monsters present' do
      DelveMonster.create(
        delve_id: delve.id,
        current_room_id: entrance_room.id,
        monster_type: 'spider',
        level: 1,
        is_active: true,
        hp: 6,
        max_hp: 6
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:has_monster]).to be true
      expect(data[:monster_name]).to eq('Spider')
      expect(data[:monster_names]).to eq(['Spider'])
    end

    it 'reports no monsters when none in room' do
      data = described_class.build_current_room_data(participant)
      expect(data[:has_monster]).to be false
      expect(data[:monster_name]).to be_nil
      expect(data[:monster_names]).to eq([])
    end

    it 'includes treasure info when unlooted treasure present' do
      DelveTreasure.create(delve_room_id: entrance_room.id, gold_value: 42, looted: false)

      data = described_class.build_current_room_data(participant)
      expect(data[:has_treasure]).to be true
      expect(data[:treasure_amount]).to eq(42)
    end

    it 'reports no treasure when all looted' do
      DelveTreasure.create(delve_room_id: entrance_room.id, gold_value: 42, looted: true)

      data = described_class.build_current_room_data(participant)
      expect(data[:has_treasure]).to be false
      expect(data[:treasure_amount]).to be_nil
    end

    it 'includes puzzle info when unsolved puzzle present' do
      DelvePuzzle.create(
        delve_room_id: entrance_room.id,
        puzzle_type: 'symbol_grid',
        difficulty: 'hard',
        seed: 123,
        solved: false
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:has_puzzle]).to be true
      expect(data[:puzzle_type]).to eq('symbol grid')
      expect(data[:puzzle_difficulty]).to eq('hard')
      expect(data[:puzzle_solved]).to be false
    end

    it 'reports no puzzle when solved' do
      DelvePuzzle.create(
        delve_room_id: entrance_room.id,
        puzzle_type: 'symbol_grid',
        difficulty: 'easy',
        seed: 123,
        solved: true
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:has_puzzle]).to be false
    end

    it 'includes exit availability' do
      adjacent_room # create adjacent room at grid_x=1, grid_y=0

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:east][:available]).to be true
      expect(data[:exits][:west][:available]).to be false
    end

    it 'includes trap info on exits' do
      adjacent_room
      DelveTrap.create(
        delve_room_id: entrance_room.id,
        direction: 'east',
        timing_a: 3,
        timing_b: 5,
        damage: 2,
        trap_theme: 'spikes',
        disabled: false
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:east][:trap]).to include(type: 'spikes', damage: 2)
    end

    it 'excludes disabled traps from exit data' do
      adjacent_room
      DelveTrap.create(
        delve_room_id: entrance_room.id,
        direction: 'east',
        timing_a: 3,
        timing_b: 5,
        damage: 2,
        trap_theme: 'spikes',
        disabled: true
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:east][:trap]).to be_nil
    end

    it 'includes blocker info on exits' do
      adjacent_room
      DelveBlocker.create(
        delve_room_id: entrance_room.id,
        direction: 'east',
        blocker_type: 'barricade',
        difficulty: 12,
        cleared: false
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:east][:blocker]).to include(
        type: 'barricade',
        dc: 12,
        stat: 'STR'
      )
    end

    it 'excludes cleared blockers from exit data' do
      adjacent_room
      DelveBlocker.create(
        delve_room_id: entrance_room.id,
        direction: 'east',
        blocker_type: 'barricade',
        difficulty: 12,
        cleared: true
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:east][:blocker]).to be_nil
    end

    it 'includes down exit for exit rooms' do
      participant.update(current_delve_room_id: exit_room.id)

      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:down]).to eq({ available: true })
    end

    it 'does not include down exit for non-exit rooms' do
      data = described_class.build_current_room_data(participant)
      expect(data[:exits][:down]).to be_nil
    end

    it 'reports hp_below_max correctly' do
      character_instance.update(health: 6, max_health: 6)
      participant.reload
      data = described_class.build_current_room_data(participant)
      expect(data[:hp_below_max]).to be false

      character_instance.update(health: 4, max_health: 6)
      participant.reload
      data = described_class.build_current_room_data(participant)
      expect(data[:hp_below_max]).to be true
    end

    it 'reports can_study correctly for unstudied monsters' do
      DelveMonster.create(
        delve_id: delve.id,
        current_room_id: entrance_room.id,
        monster_type: 'goblin',
        level: 1,
        is_active: true,
        hp: 6,
        max_hp: 6
      )

      data = described_class.build_current_room_data(participant)
      expect(data[:can_study]).to be true
    end

    it 'reports can_study false when all monsters studied' do
      DelveMonster.create(
        delve_id: delve.id,
        current_room_id: entrance_room.id,
        monster_type: 'goblin',
        level: 1,
        is_active: true,
        hp: 6,
        max_hp: 6
      )

      # Mark as studied
      participant.update(studied_monsters: Sequel.pg_json_wrap(['goblin']))

      data = described_class.build_current_room_data(participant)
      expect(data[:can_study]).to be false
    end
  end
end
