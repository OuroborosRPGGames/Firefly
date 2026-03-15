# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveRoom do
  let(:delve) { create(:delve) }

  describe 'associations' do
    it 'belongs to delve' do
      room = DelveRoom.new(delve_id: delve.id)
      expect(room.delve).to eq(delve)
    end

    it 'belongs to parent_room (optional)' do
      parent = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
      child = DelveRoom.create(delve_id: delve.id, room_type: 'branch', depth: 2, parent_room_id: parent.id, grid_x: 1, grid_y: 0)

      expect(child.parent_room).to eq(parent)
    end

    it 'has many child_rooms' do
      parent = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
      child1 = DelveRoom.create(delve_id: delve.id, room_type: 'branch', depth: 2, parent_room_id: parent.id, grid_x: 1, grid_y: 0)
      child2 = DelveRoom.create(delve_id: delve.id, room_type: 'corner', depth: 2, parent_room_id: parent.id, grid_x: 0, grid_y: 1)

      expect(parent.child_rooms).to include(child1, child2)
    end

    describe 'room association' do
      it 'can reference a real Room via room_id' do
        location = create(:location)
        room = create(:room, location: location, name: 'Delve Chamber')
        delve_room = create(:delve_room, delve: delve, room_id: room.id)

        expect(delve_room.room).to eq(room)
        expect(delve_room.room.name).to eq('Delve Chamber')
      end

      it 'returns nil when no room is linked' do
        delve_room = create(:delve_room, delve: delve)

        expect(delve_room.room).to be_nil
      end
    end
  end

  describe 'validations' do
    it 'requires delve_id' do
      room = DelveRoom.new(room_type: 'branch', depth: 1)
      expect(room.valid?).to be false
      expect(room.errors[:delve_id]).not_to be_empty
    end

    it 'requires room_type' do
      room = DelveRoom.new(delve_id: delve.id, depth: 1)
      expect(room.valid?).to be false
      expect(room.errors[:room_type]).not_to be_empty
    end

    it 'requires depth' do
      room = DelveRoom.new(delve_id: delve.id, room_type: 'branch')
      expect(room.valid?).to be false
      expect(room.errors[:depth]).not_to be_empty
    end

    it 'validates room_type is in ROOM_TYPES' do
      room = DelveRoom.new(delve_id: delve.id, room_type: 'invalid', depth: 1)
      expect(room.valid?).to be false
      expect(room.errors[:room_type]).not_to be_empty
    end

    it 'accepts valid room types' do
      DelveRoom::ROOM_TYPES.each do |type|
        room = DelveRoom.new(delve_id: delve.id, room_type: type, depth: 1)
        expect(room.valid?).to be true
      end
    end
  end

  describe 'before_save defaults' do
    let(:room) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1) }

    it 'sets explored to false by default' do
      expect(room.explored).to be false
    end

    it 'sets cleared to false by default' do
      expect(room.cleared).to be false
    end
  end

  describe 'state methods' do
    let(:room) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0) }

    describe '#explore!' do
      it 'sets explored to true' do
        room.explore!
        expect(room.explored).to be true
      end

      it 'sets explored_at timestamp' do
        room.explore!
        expect(room.explored_at).not_to be_nil
      end
    end

    describe '#clear!' do
      it 'sets cleared to true' do
        room.clear!
        expect(room.cleared).to be true
      end

      it 'sets cleared_at timestamp' do
        room.clear!
        expect(room.cleared_at).not_to be_nil
      end
    end

    describe '#explored?' do
      it 'returns true when explored' do
        room.update(explored: true)
        expect(room.explored?).to be true
      end

      it 'returns false when not explored' do
        expect(room.explored?).to be false
      end
    end

    describe '#cleared?' do
      it 'returns true when cleared' do
        room.update(cleared: true)
        expect(room.cleared?).to be true
      end

      it 'returns false when not cleared' do
        expect(room.cleared?).to be false
      end
    end
  end

  describe 'room type helpers' do
    describe '#dangerous?' do
      it 'returns true when room has a monster' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0, monster_type: 'goblin')
        expect(room.dangerous?).to be true
      end

      it 'returns true when room has an active trap' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: false)
        expect(room.dangerous?).to be true
      end

      it 'returns false when trap is disabled' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: true)
        expect(room.dangerous?).to be false
      end

      it 'returns false for rooms with no monster or trap' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'branch', depth: 1, grid_x: 0, grid_y: 0)
        expect(room.dangerous?).to be false
      end

      it 'returns false for corridor rooms with no content' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        expect(room.dangerous?).to be false
      end
    end

    describe '#has_loot?' do
      it 'returns true when has_treasure is true' do
        room = DelveRoom.new(room_type: 'terminal', has_treasure: true)
        expect(room.has_loot?).to be true
      end

      it 'returns false when has_treasure is false' do
        room = DelveRoom.new(room_type: 'terminal', has_treasure: false)
        expect(room.has_loot?).to be false
      end

      it 'returns false when has_treasure is nil' do
        room = DelveRoom.new(room_type: 'corridor')
        expect(room.has_loot?).to be false
      end
    end

    describe '#exit_room?' do
      it 'returns true when is_exit flag is true' do
        room = DelveRoom.new(room_type: 'terminal', is_exit: true)
        expect(room.exit_room?).to be true
      end

      it 'returns false when is_exit flag is false' do
        room = DelveRoom.new(room_type: 'corridor', is_exit: false)
        expect(room.exit_room?).to be false
      end

      it 'returns false when is_exit is nil' do
        room = DelveRoom.new(room_type: 'corridor')
        expect(room.exit_room?).to be false
      end
    end

    describe '#has_stairs_down?' do
      it 'returns true when room is an exit' do
        room = DelveRoom.new(room_type: 'terminal', is_exit: true)
        expect(room.has_stairs_down?).to be true
      end

      it 'returns false when room is not an exit' do
        room = DelveRoom.new(room_type: 'corridor', is_exit: false)
        expect(room.has_stairs_down?).to be false
      end
    end

    describe '#boss?' do
      it 'returns true when is_boss flag is true' do
        room = DelveRoom.new(room_type: 'branch', is_boss: true)
        expect(room.boss?).to be true
      end

      it 'returns false when is_boss flag is false' do
        room = DelveRoom.new(room_type: 'corridor', is_boss: false)
        expect(room.boss?).to be false
      end

      it 'returns false when is_boss is nil' do
        room = DelveRoom.new(room_type: 'corridor')
        expect(room.boss?).to be false
      end
    end
  end

  describe 'grid navigation' do
    let!(:room_center) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 5, grid_y: 5) }
    let!(:room_north) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 5, grid_y: 4) }
    let!(:room_south) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 5, grid_y: 6) }
    let!(:room_east) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, level: 1, grid_x: 6, grid_y: 5) }

    describe '#position' do
      it 'returns grid position as array' do
        expect(room_center.position).to eq([5, 5])
      end
    end

    describe '#coordinate_key' do
      it 'returns unique coordinate key' do
        expect(room_center.coordinate_key).to eq('1:5,5')
      end
    end

    describe '#available_exits' do
      it 'finds adjacent rooms' do
        exits = room_center.available_exits
        expect(exits).to include('north')
        expect(exits).to include('south')
        expect(exits).to include('east')
        expect(exits).not_to include('west')
      end

      it 'includes down for exit rooms' do
        room_center.update(is_exit: true)
        exits = room_center.available_exits
        expect(exits).to include('down')
      end

      it 'returns empty array when delve is nil' do
        room = DelveRoom.new(grid_x: 0, grid_y: 0)
        expect(room.available_exits).to eq([])
      end
    end

    describe '#can_go?' do
      it 'returns true for available direction' do
        expect(room_center.can_go?('north')).to be true
      end

      it 'returns false for unavailable direction' do
        expect(room_center.can_go?('west')).to be false
      end

      it 'is case insensitive' do
        expect(room_center.can_go?('NORTH')).to be true
      end
    end
  end

  describe 'action handlers' do
    describe '#search!' do
      let(:room) { DelveRoom.create(delve_id: delve.id, room_type: 'terminal', depth: 1, grid_x: 0, grid_y: 0, has_treasure: true) }

      it 'marks room as searched' do
        room.search!
        expect(room.searched?).to be true
      end

      it 'sets searched_at timestamp' do
        room.search!
        expect(room.searched_at).not_to be_nil
      end

      it 'returns true on first search' do
        expect(room.search!).to be true
      end

      it 'returns false if already searched' do
        room.update(searched: true)
        expect(room.search!).to be false
      end
    end

    describe '#trigger_trap!' do
      let(:trap_room) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0, trap_damage: 15) }

      it 'returns damage and marks triggered' do
        damage = trap_room.trigger_trap!
        expect(damage).to eq(15)
        expect(trap_room.trap_triggered).to be true
      end

      it 'returns 0 if already triggered' do
        trap_room.update(trap_triggered: true)
        expect(trap_room.trigger_trap!).to eq(0)
      end

      it 'returns 0 for rooms with no trap_damage' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 1, grid_y: 0)
        expect(room.trigger_trap!).to eq(0)
      end
    end

    describe '#clear_monster!' do
      let(:monster_room) { DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0, monster_type: 'goblin') }

      it 'clears monster and room' do
        monster_room.clear_monster!
        expect(monster_room.monster_cleared).to be true
        expect(monster_room.cleared).to be true
      end

      it 'sets cleared_at timestamp' do
        monster_room.clear_monster!
        expect(monster_room.cleared_at).not_to be_nil
      end

      it 'returns true on success' do
        expect(monster_room.clear_monster!).to be true
      end

      it 'returns false if already cleared' do
        monster_room.update(monster_cleared: true)
        expect(monster_room.clear_monster!).to be false
      end

      it 'returns false if no monster_type' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 1, grid_y: 0)
        expect(room.clear_monster!).to be false
      end
    end
  end

  describe 'monster and trap checks' do
    describe '#has_monster?' do
      it 'returns true when monster present and not cleared' do
        room = DelveRoom.new(monster_type: 'goblin', monster_cleared: false)
        expect(room.has_monster?).to be true
      end

      it 'returns false when monster cleared' do
        room = DelveRoom.new(monster_type: 'goblin', monster_cleared: true)
        expect(room.has_monster?).to be false
      end

      it 'returns falsey when no monster_type' do
        room = DelveRoom.new(monster_type: nil)
        expect(room.has_monster?).to be_falsey
      end

      it 'returns false when monster_type is empty' do
        room = DelveRoom.new(monster_type: '')
        expect(room.has_monster?).to be false
      end
    end

    describe '#has_trap?' do
      it 'returns true when active DelveTrap exists' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: false)
        expect(room.has_trap?).to be true
      end

      it 'returns false when all traps are disabled' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: true)
        expect(room.has_trap?).to be false
      end

      it 'returns false when no traps exist' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        expect(room.has_trap?).to be false
      end
    end

    describe '#safe?' do
      it 'returns true when no monster or trap' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        expect(room.safe?).to be true
      end

      it 'returns false when has monster' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0, monster_type: 'goblin', monster_cleared: false)
        expect(room.safe?).to be false
      end

      it 'returns false when has active trap' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: false)
        expect(room.safe?).to be false
      end

      it 'returns true when monster cleared and traps disabled' do
        room = DelveRoom.create(delve_id: delve.id, room_type: 'corridor', depth: 1, grid_x: 0, grid_y: 0, monster_type: 'goblin', monster_cleared: true)
        DelveTrap.create(delve_room_id: room.id, timing_a: 3, timing_b: 7, disabled: true)
        expect(room.safe?).to be true
      end
    end
  end

  describe '#description_text' do
    it 'returns base description for corridor' do
      room = DelveRoom.new(room_type: 'corridor')
      expect(room.description_text).to include('narrow stone corridor')
    end

    it 'returns base description for branch' do
      room = DelveRoom.new(room_type: 'branch')
      expect(room.description_text).to include('spacious chamber')
    end

    it 'includes monster warning when monster present' do
      room = DelveRoom.new(room_type: 'corridor', monster_type: 'goblin', monster_cleared: false)
      expect(room.description_text).to include('[DANGER]')
      expect(room.description_text).to include('goblin')
    end

    it 'includes combat signs when monster cleared' do
      room = DelveRoom.new(room_type: 'corridor', monster_type: 'goblin', monster_cleared: true)
      expect(room.description_text).to include('Signs of recent combat')
    end

    it 'includes treasure hint when has_treasure and not searched' do
      room = DelveRoom.new(room_type: 'terminal', has_treasure: true, searched: false)
      expect(room.description_text).to include('treasure')
    end
  end

  describe 'factory traits' do
    it 'creates with :monster trait' do
      room = create(:delve_room, :monster, delve: delve)
      expect(room.room_type).to eq('corridor')
      expect(room.monster_type).to eq('goblin')
    end

    it 'creates with :trap trait' do
      room = create(:delve_room, :trap, delve: delve)
      expect(room.room_type).to eq('corridor')
      expect(room.trap_damage).to eq(10)
    end

    it 'creates with :explored trait' do
      room = create(:delve_room, :explored, delve: delve)
      expect(room.explored).to be true
      expect(room.explored_at).not_to be_nil
    end

    it 'creates with :boss trait' do
      room = create(:delve_room, :boss, delve: delve)
      expect(room.room_type).to eq('branch')
      expect(room.monster_type).to eq('dragon')
      expect(room.is_boss).to be true
    end
  end
end
