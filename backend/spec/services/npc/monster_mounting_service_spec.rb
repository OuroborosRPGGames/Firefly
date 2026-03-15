# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterMountingService do
  let(:fight) { double('Fight', id: 1, arena_width: 20, arena_height: 20, room: nil) }
  let(:service) { described_class.new(fight) }

  describe '#initialize' do
    it 'accepts a fight parameter' do
      expect(service.instance_variable_get(:@fight)).to eq(fight)
    end
  end

  describe '#attempt_mount' do
    let(:monster_template) { double('MonsterTemplate', hex_width: 2, hex_height: 2) }
    let(:monster) do
      double('LargeMonsterInstance',
        id: 1,
        center_hex_x: 10,
        center_hex_y: 10,
        monster_template: monster_template
      )
    end
    let(:participant) do
      double('FightParticipant',
        id: 100,
        hex_x: 9,
        hex_y: 10,
        is_mounted: false
      )
    end
    let(:hex_service) { double('MonsterHexService') }
    let(:closest_segment) { double('MonsterSegmentInstance', id: 50) }

    before do
      allow(MonsterHexService).to receive(:new).with(monster).and_return(hex_service)
      allow(monster).to receive(:closest_segment_to).with(9, 10).and_return(closest_segment)
    end

    context 'when participant is already mounted' do
      before do
        allow(participant).to receive(:is_mounted).and_return(true)
      end

      it 'returns error' do
        result = service.attempt_mount(participant, monster)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Already mounted on a monster')
      end
    end

    context 'when participant is not adjacent to monster' do
      before do
        allow(hex_service).to receive(:adjacent_to_monster?).with(participant).and_return(false)
      end

      it 'returns error' do
        result = service.attempt_mount(participant, monster)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Must be adjacent to the monster to mount')
      end
    end

    context 'when conditions are met' do
      let(:mount_state) { double('MonsterMountState') }

      before do
        allow(hex_service).to receive(:adjacent_to_monster?).with(participant).and_return(true)
        allow(MonsterMountState).to receive(:create).and_return(mount_state)
        allow(participant).to receive(:update)
      end

      it 'creates mount state' do
        expect(MonsterMountState).to receive(:create).with(
          large_monster_instance_id: monster.id,
          fight_participant_id: participant.id,
          current_segment_id: closest_segment.id,
          climb_progress: 0,
          mount_status: 'mounted',
          mounted_at: kind_of(Time)
        )

        service.attempt_mount(participant, monster)
      end

      it 'updates participant state' do
        expect(participant).to receive(:update).with(
          is_mounted: true,
          mount_action: 'cling',
          targeting_monster_id: monster.id,
          targeting_segment_id: closest_segment.id
        )

        service.attempt_mount(participant, monster)
      end

      it 'returns success with mount state' do
        result = service.attempt_mount(participant, monster)
        expect(result[:success]).to be true
        expect(result[:mount_state]).to eq(mount_state)
        expect(result[:segment]).to eq(closest_segment)
      end
    end
  end

  describe '#process_climb' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:weak_point) { double('MonsterSegmentInstance', id: 99) }
    let(:participant) { double('FightParticipant') }
    let(:mount_state) do
      double('MonsterMountState',
        climb_distance: 5,
        large_monster_instance: monster,
        fight_participant: participant
      )
    end

    before do
      allow(mount_state).to receive(:set_climbing!)
    end

    context 'when not at weak point yet' do
      before do
        allow(mount_state).to receive(:advance_climb!).and_return({
          reached_weak_point: false,
          progress: 3
        })
      end

      it 'returns progress' do
        result = service.process_climb(mount_state)
        expect(result[:success]).to be true
        expect(result[:progress]).to eq(3)
        expect(result[:at_weak_point]).to be false
      end
    end

    context 'when reaching weak point' do
      before do
        allow(mount_state).to receive(:advance_climb!).and_return({
          reached_weak_point: true,
          progress: 10
        })
        allow(monster).to receive(:weak_point_segment).and_return(weak_point)
        allow(mount_state).to receive(:update)
        allow(participant).to receive(:update)
      end

      it 'updates segment targeting' do
        expect(mount_state).to receive(:update).with(current_segment_id: weak_point.id)
        expect(participant).to receive(:update).with(targeting_segment_id: weak_point.id)

        service.process_climb(mount_state)
      end

      it 'returns at_weak_point true' do
        result = service.process_climb(mount_state)
        expect(result[:at_weak_point]).to be true
      end
    end
  end

  describe '#process_cling' do
    let(:mount_state) { double('MonsterMountState') }

    before do
      allow(mount_state).to receive(:set_cling!)
    end

    it 'sets cling status' do
      expect(mount_state).to receive(:set_cling!)
      service.process_cling(mount_state)
    end

    it 'returns success' do
      result = service.process_cling(mount_state)
      expect(result[:success]).to be true
      expect(result[:status]).to eq('clinging')
    end
  end

  describe '#process_dismount' do
    let(:monster_template) { double('MonsterTemplate', hex_width: 2, hex_height: 2) }
    let(:monster) do
      double('LargeMonsterInstance',
        id: 1,
        center_hex_x: 10,
        center_hex_y: 10,
        monster_template: monster_template
      )
    end
    let(:participant) { double('FightParticipant', id: 100) }
    let(:mount_state) do
      double('MonsterMountState',
        large_monster_instance: monster,
        fight_participant: participant
      )
    end
    let(:hex_service) { double('MonsterHexService') }

    before do
      allow(MonsterHexService).to receive(:new).with(monster).and_return(hex_service)
      allow(mount_state).to receive(:dismount!)
    end

    context 'when adjacent hex is found' do
      before do
        allow(hex_service).to receive(:closest_mounting_hex).and_return([8, 10])
      end

      it 'dismounts to adjacent hex' do
        expect(mount_state).to receive(:dismount!).with(8, 10)
        service.process_dismount(mount_state)
      end

      it 'returns landing position' do
        result = service.process_dismount(mount_state)
        expect(result[:success]).to be true
        expect(result[:landing_position]).to eq([8, 10])
      end
    end

    context 'when no adjacent hex found' do
      before do
        allow(hex_service).to receive(:closest_mounting_hex).and_return(nil)
        allow(hex_service).to receive(:calculate_scatter_position).and_return([5, 5])
      end

      it 'uses scatter position' do
        expect(mount_state).to receive(:dismount!).with(5, 5)
        service.process_dismount(mount_state)
      end
    end
  end

  describe '#process_shake_off' do
    let(:monster_template) { double('MonsterTemplate', hex_width: 2, hex_height: 2) }
    let(:monster) do
      double('LargeMonsterInstance',
        id: 1,
        monster_template: monster_template
      )
    end
    let(:hex_service) { double('MonsterHexService') }
    let(:clinging_participant) { double('FightParticipant', character_name: 'Clinger') }
    let(:climbing_participant) { double('FightParticipant', character_name: 'Climber') }
    let(:clinging_state) do
      double('MonsterMountState',
        mount_status: 'mounted',
        fight_participant: clinging_participant
      )
    end
    let(:climbing_state) do
      double('MonsterMountState',
        mount_status: 'climbing',
        fight_participant: climbing_participant
      )
    end

    before do
      allow(MonsterHexService).to receive(:new).with(monster).and_return(hex_service)
      allow(monster).to receive(:monster_mount_states).and_return([clinging_state, climbing_state])
    end

    context 'with clinging participant' do
      before do
        allow(clinging_state).to receive(:mount_action_is_cling?).and_return(true)
        allow(climbing_state).to receive(:mount_action_is_cling?).and_return(false)
        allow(hex_service).to receive(:calculate_scatter_position).and_return([5, 5])
        allow(hex_service).to receive(:check_hazard_at).and_return(nil)
        allow(climbing_state).to receive(:throw_off!)
      end

      it 'keeps clinging participants mounted' do
        result = service.process_shake_off(monster)
        clinger_result = result[:results].find { |r| r[:participant_name] == 'Clinger' }
        expect(clinger_result[:thrown]).to be false
        expect(clinger_result[:reason]).to eq('clinging')
      end

      it 'throws off non-clinging participants' do
        result = service.process_shake_off(monster)
        climber_result = result[:results].find { |r| r[:participant_name] == 'Climber' }
        expect(climber_result[:thrown]).to be true
        expect(climber_result[:landing_x]).to eq(5)
        expect(climber_result[:landing_y]).to eq(5)
      end

      it 'returns correct thrown count' do
        result = service.process_shake_off(monster)
        expect(result[:thrown_count]).to eq(1)
      end
    end

    context 'when landing in hazard' do
      let(:hazard) { double('RoomHex', hazard_type: 'fire') }

      before do
        allow(clinging_state).to receive(:mount_action_is_cling?).and_return(false)
        allow(climbing_state).to receive(:mount_action_is_cling?).and_return(false)
        allow(hex_service).to receive(:calculate_scatter_position).and_return([5, 5])
        allow(hex_service).to receive(:check_hazard_at).and_return(hazard)
        allow(clinging_state).to receive(:throw_off!)
        allow(climbing_state).to receive(:throw_off!)
      end

      it 'reports hazard landing' do
        result = service.process_shake_off(monster)
        expect(result[:results].first[:landed_in_hazard]).to be true
        expect(result[:results].first[:hazard_type]).to eq('fire')
      end
    end

    context 'when mount state is already dismounted' do
      let(:dismounted_state) do
        double('MonsterMountState', mount_status: 'dismounted')
      end

      before do
        allow(monster).to receive(:monster_mount_states).and_return([dismounted_state])
      end

      it 'skips dismounted states' do
        result = service.process_shake_off(monster)
        expect(result[:results]).to be_empty
        expect(result[:thrown_count]).to eq(0)
      end
    end
  end

  describe '#target_segment' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:participant) { double('FightParticipant', id: 100, hex_x: 8, hex_y: 10) }
    let(:current_segment) { double('MonsterSegmentInstance', name: 'Claw') }

    context 'when participant is mounted with segment' do
      let(:mount_state) { double('MonsterMountState', current_segment: current_segment) }

      before do
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
      end

      it 'returns current segment' do
        result = service.target_segment(participant, monster)
        expect(result).to eq(current_segment)
      end
    end

    context 'when participant is not mounted' do
      let(:closest_segment) { double('MonsterSegmentInstance', name: 'Body') }

      before do
        allow(MonsterMountState).to receive(:first).and_return(nil)
        allow(monster).to receive(:closest_segment_to).with(8, 10).and_return(closest_segment)
      end

      it 'returns closest segment geometrically' do
        result = service.target_segment(participant, monster)
        expect(result).to eq(closest_segment)
      end
    end
  end

  describe '#at_weak_point?' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:participant) { double('FightParticipant', id: 100) }

    context 'when at weak point' do
      let(:mount_state) { double('MonsterMountState') }

      before do
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(mount_state).to receive(:at_weak_point?).and_return(true)
      end

      it 'returns true' do
        expect(service.at_weak_point?(participant, monster)).to be true
      end
    end

    context 'when not at weak point' do
      let(:mount_state) { double('MonsterMountState') }

      before do
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(mount_state).to receive(:at_weak_point?).and_return(false)
      end

      it 'returns false' do
        expect(service.at_weak_point?(participant, monster)).to be false
      end
    end

    context 'when not mounted' do
      before do
        allow(MonsterMountState).to receive(:first).and_return(nil)
      end

      it 'returns false' do
        expect(service.at_weak_point?(participant, monster)).to be false
      end
    end
  end

  describe '#mount_state' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:participant) { double('FightParticipant', id: 100) }
    let(:mount_state) { double('MonsterMountState') }

    before do
      allow(MonsterMountState).to receive(:first).with(
        large_monster_instance_id: 1,
        fight_participant_id: 100
      ).and_return(mount_state)
    end

    it 'returns mount state' do
      expect(service.mount_state(participant, monster)).to eq(mount_state)
    end
  end

  describe '#all_mount_states' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:active_state) { double('MonsterMountState', mount_status: 'mounted') }
    let(:dismounted_state) { double('MonsterMountState', mount_status: 'dismounted') }

    before do
      allow(monster).to receive(:monster_mount_states).and_return([active_state, dismounted_state])
    end

    it 'excludes dismounted states' do
      result = service.all_mount_states(monster)
      expect(result).to include(active_state)
      expect(result).not_to include(dismounted_state)
    end
  end

  describe '#apply_thrown_positions' do
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:thrown_state) { double('MonsterMountState', mount_status: 'thrown') }
    let(:mounted_state) { double('MonsterMountState', mount_status: 'mounted') }

    before do
      allow(monster).to receive(:monster_mount_states).and_return([thrown_state, mounted_state])
    end

    it 'applies throw to thrown states only' do
      expect(thrown_state).to receive(:apply_throw!)
      expect(mounted_state).not_to receive(:apply_throw!)

      service.apply_thrown_positions(monster)
    end
  end
end
