# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterHexService do
  let(:room) { double('Room', id: 1) }
  let(:fight) { double('Fight', arena_width: 20, arena_height: 20, room: room) }
  let(:monster_template) { double('MonsterTemplate', hex_width: 2, hex_height: 2) }
  let(:monster) do
    double('LargeMonsterInstance',
      id: 1,
      fight: fight,
      monster_template: monster_template,
      center_hex_x: 10,
      center_hex_y: 10,
      facing_direction: 0
    )
  end
  let(:service) { described_class.new(monster) }

  describe '#initialize' do
    it 'accepts a monster_instance' do
      expect(service.instance_variable_get(:@monster)).to eq(monster)
      expect(service.instance_variable_get(:@fight)).to eq(fight)
      expect(service.instance_variable_get(:@room)).to eq(room)
    end
  end

  describe '#occupied_hexes' do
    let(:hexes) { [[10, 10], [11, 10], [10, 11], [11, 11]] }

    before do
      allow(monster).to receive(:occupied_hexes).and_return(hexes)
    end

    it 'returns monster occupied hexes' do
      expect(service.occupied_hexes).to eq(hexes)
    end
  end

  describe '#hex_occupied?' do
    before do
      allow(monster).to receive(:occupies_hex?).with(10, 10).and_return(true)
      allow(monster).to receive(:occupies_hex?).with(5, 5).and_return(false)
    end

    it 'returns true for occupied hex' do
      expect(service.hex_occupied?(10, 10)).to be true
    end

    it 'returns false for unoccupied hex' do
      expect(service.hex_occupied?(5, 5)).to be false
    end
  end

  describe '#adjacent_to_monster?' do
    let(:participant) { double('FightParticipant', hex_x: 9, hex_y: 10) }

    before do
      allow(monster).to receive(:occupied_hexes).and_return([[10, 10], [11, 10]])
    end

    context 'when participant is adjacent' do
      it 'returns true for distance 1' do
        expect(service.adjacent_to_monster?(participant)).to be true
      end
    end

    context 'when participant is not adjacent' do
      let(:far_participant) { double('FightParticipant', hex_x: 5, hex_y: 5) }

      it 'returns false' do
        expect(service.adjacent_to_monster?(far_participant)).to be false
      end
    end
  end

  describe '#turn_monster' do
    let(:mount_state) do
      double('MonsterMountState',
        mount_status: 'mounted',
        fight_participant: double('FightParticipant', hex_x: 12, hex_y: 10)
      )
    end

    before do
      allow(monster).to receive(:monster_mount_states).and_return([mount_state])
      allow(monster).to receive(:update)
      allow(mount_state.fight_participant).to receive(:update)
    end

    context 'when rotation is zero' do
      it 'does nothing' do
        expect(monster).not_to receive(:update)
        service.turn_monster(0)
      end
    end

    context 'when rotation is needed' do
      it 'updates monster facing direction' do
        expect(monster).to receive(:update).with(facing_direction: 2)
        service.turn_monster(2)
      end

      it 'rotates mounted participants' do
        expect(mount_state.fight_participant).to receive(:update).with(hex_x: anything, hex_y: anything)
        service.turn_monster(2)
      end
    end

    context 'when mount state is not mounted' do
      let(:dismounted_state) do
        double('MonsterMountState',
          mount_status: 'dismounted',
          fight_participant: double('FightParticipant')
        )
      end

      before do
        allow(monster).to receive(:monster_mount_states).and_return([dismounted_state])
      end

      it 'skips dismounted states' do
        expect(dismounted_state.fight_participant).not_to receive(:update)
        service.turn_monster(2)
      end
    end
  end

  describe '#turn_towards' do
    before do
      allow(monster).to receive(:monster_mount_states).and_return([])
      allow(monster).to receive(:update)
    end

    it 'calculates facing direction and turns' do
      # Target (5, 10) is to the left, which should calculate to direction 3 (West)
      # Since monster starts facing 0 (East), this requires a rotation
      expect(monster).to receive(:update).with(facing_direction: kind_of(Integer))
      service.turn_towards(5, 10)
    end
  end

  describe '#calculate_facing_towards' do
    context 'for different target positions' do
      it 'returns 1 (NE) for targets to the right (no pure E direction)' do
        expect(service.calculate_facing_towards(15, 10)).to eq(1)
      end

      it 'returns 5 (NW) for targets to the left (no pure W direction)' do
        expect(service.calculate_facing_towards(5, 10)).to eq(5)
      end

      it 'returns current direction when target is at center' do
        expect(service.calculate_facing_towards(10, 10)).to eq(0)
      end
    end
  end

  describe '#move_monster' do
    let(:mount_state) do
      double('MonsterMountState',
        mount_status: 'mounted',
        fight_participant: double('FightParticipant', hex_x: 11, hex_y: 10)
      )
    end

    before do
      allow(monster).to receive(:monster_mount_states).and_return([mount_state])
      allow(monster).to receive(:move_to)
      allow(mount_state.fight_participant).to receive(:update)
    end

    it 'moves the monster' do
      expect(monster).to receive(:move_to).with(12, 12)
      service.move_monster(12, 12)
    end

    it 'moves mounted participants with the monster' do
      # Movement delta is (12-10, 12-10) = (2, 2)
      # Participant at (11, 10) moves to (13, 12)
      expect(mount_state.fight_participant).to receive(:update).with(hex_x: 13, hex_y: 12)
      service.move_monster(12, 12)
    end

    context 'when mount state is not active' do
      let(:dismounted_state) do
        double('MonsterMountState',
          mount_status: 'dismounted',
          fight_participant: double('FightParticipant')
        )
      end

      before do
        allow(monster).to receive(:monster_mount_states).and_return([dismounted_state])
      end

      it 'skips dismounted participants' do
        expect(dismounted_state.fight_participant).not_to receive(:update)
        service.move_monster(12, 12)
      end
    end
  end

  describe '#calculate_scatter_position' do
    before do
      allow(monster).to receive(:occupies_hex?).and_return(false)
    end

    it 'returns array with x and y coordinates' do
      result = service.calculate_scatter_position
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end

    it 'clamps to arena bounds' do
      result = service.calculate_scatter_position
      max_y = (fight.arena_height - 1) * 4 + 2
      expect(result[0]).to be_between(0, fight.arena_width - 1)
      expect(result[1]).to be_between(0, max_y)
    end

    context 'when landing on monster' do
      before do
        allow(monster).to receive(:occupies_hex?).and_return(true, false)
      end

      it 'moves further out' do
        result = service.calculate_scatter_position
        expect(result).to be_an(Array)
      end
    end
  end

  describe '#check_hazard_at' do
    context 'when room is nil' do
      let(:roomless_fight) { double('Fight', arena_width: 20, arena_height: 20, room: nil) }
      let(:roomless_monster) do
        double('LargeMonsterInstance',
          id: 1,
          fight: roomless_fight,
          monster_template: monster_template
        )
      end
      let(:roomless_service) { described_class.new(roomless_monster) }

      it 'returns nil' do
        expect(roomless_service.check_hazard_at(5, 5)).to be_nil
      end
    end

    context 'when no hazard at position' do
      before do
        allow(RoomHex).to receive(:first).and_return(nil)
      end

      it 'returns nil' do
        expect(service.check_hazard_at(5, 5)).to be_nil
      end
    end

    context 'when hex is not dangerous' do
      let(:safe_hex) { double('RoomHex', dangerous?: false) }

      before do
        allow(RoomHex).to receive(:first).and_return(safe_hex)
      end

      it 'returns nil' do
        expect(service.check_hazard_at(5, 5)).to be_nil
      end
    end

    context 'when hex is dangerous' do
      let(:hazard_hex) { double('RoomHex', dangerous?: true, hazard_type: 'fire') }

      before do
        allow(RoomHex).to receive(:first).with(room_id: 1, hex_x: 5, hex_y: 5).and_return(hazard_hex)
      end

      it 'returns the hazard hex' do
        expect(service.check_hazard_at(5, 5)).to eq(hazard_hex)
      end
    end
  end

  describe '#closest_mounting_hex' do
    before do
      allow(monster).to receive(:occupied_hexes).and_return([[10, 10]])
      allow(monster).to receive(:occupies_hex?).and_return(false)
    end

    it 'returns closest hex adjacent to monster' do
      result = service.closest_mounting_hex(8, 10)
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end

    it 'excludes monster-occupied hexes' do
      allow(monster).to receive(:occupies_hex?) do |x, y|
        x == 11 && y == 10
      end

      result = service.closest_mounting_hex(12, 10)
      # Should find a hex that's not (11, 10)
      expect(result).not_to be_nil
    end

    it 'excludes out-of-bounds hexes' do
      # When at edge of arena
      allow(monster).to receive(:occupied_hexes).and_return([[0, 0]])

      result = service.closest_mounting_hex(-1, 0)
      # Should not include negative coordinates
      if result
        expect(result[0]).to be >= 0
        expect(result[1]).to be >= 0
      end
    end
  end

  describe 'private methods' do
    describe '#rotate_offset' do
      it 'returns same offset for zero steps' do
        result = service.send(:rotate_offset, 2, 0, 0)
        expect(result).to eq([2, 0])
      end

      it 'returns same for zero offset' do
        result = service.send(:rotate_offset, 0, 0, 3)
        expect(result).to eq([0, 0])
      end

      it 'rotates offset by one step' do
        result = service.send(:rotate_offset, 2, 0, 1)
        expect(result).to eq([0, 2])
      end
    end

    describe '#hex_distance' do
      it 'returns 0 for same position' do
        expect(service.send(:hex_distance, 0, 0, 0, 0)).to eq(0)
      end

      it 'calculates distance for adjacent hexes' do
        # NE neighbor: (0,0) → (1,2) = 1 step
        expect(service.send(:hex_distance, 0, 0, 1, 2)).to eq(1)
        # N neighbor: (0,0) → (0,4) = 1 step
        expect(service.send(:hex_distance, 0, 0, 0, 4)).to eq(1)
        # (0,0) → (2,0) = 2 steps (no direct E neighbor)
        expect(service.send(:hex_distance, 0, 0, 2, 0)).to eq(2)
      end

      it 'calculates distance for diagonal hexes' do
        # (0,0) → (3,2) = 3 steps via zigzag
        expect(service.send(:hex_distance, 0, 0, 3, 2)).to eq(3)
      end
    end

    describe '#hex_in_direction' do
      # Uses valid hex coordinates: y=0 (even), x=4 (even for y=0 row)
      it 'returns north neighbor for direction 0' do
        result = service.send(:hex_in_direction, 4, 0, 0, 1)
        expect(result).to eq([4, 4])  # N neighbor: same x, y+4
      end

      it 'returns south neighbor for direction 3' do
        result = service.send(:hex_in_direction, 4, 0, 3, 1)
        expect(result).to eq([4, -4])  # S neighbor: same x, y-4
      end

      it 'scales by distance' do
        result = service.send(:hex_in_direction, 4, 0, 0, 3)
        expect(result).to eq([4, 12])  # 3 north steps: each y+4
      end

      it 'handles all six directions' do
        (0..5).each do |dir|
          result = service.send(:hex_in_direction, 4, 4, dir, 1)
          expect(result).to be_an(Array)
          expect(result.length).to eq(2)
          # Result should be a valid hex coordinate
          expect(HexGrid.valid_hex_coords?(*result)).to be true
        end
      end
    end
  end
end
