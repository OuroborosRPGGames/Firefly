# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterMountState do
  let(:fight) { create(:fight) }
  let(:monster_template) { create(:monster_template, climb_distance: 5) }
  let(:monster_instance) { create(:large_monster_instance, monster_template: monster_template, fight: fight) }
  let(:fight_participant) { create(:fight_participant, fight: fight) }

  describe 'associations' do
    it 'belongs to monster_instance' do
      mount_state = MonsterMountState.new(large_monster_instance_id: monster_instance.id)
      expect(mount_state.large_monster_instance.id).to eq(monster_instance.id)
    end

    it 'belongs to fight_participant' do
      mount_state = MonsterMountState.new(fight_participant_id: fight_participant.id)
      expect(mount_state.fight_participant.id).to eq(fight_participant.id)
    end
  end

  describe 'validations' do
    it 'requires large_monster_instance_id' do
      mount_state = MonsterMountState.new(
        fight_participant_id: fight_participant.id,
        climb_progress: 0
      )
      expect(mount_state.valid?).to be false
      expect(mount_state.errors[:large_monster_instance_id]).not_to be_empty
    end

    it 'requires fight_participant_id' do
      mount_state = MonsterMountState.new(
        large_monster_instance_id: monster_instance.id,
        climb_progress: 0
      )
      expect(mount_state.valid?).to be false
      expect(mount_state.errors[:fight_participant_id]).not_to be_empty
    end

    it 'requires climb_progress' do
      mount_state = MonsterMountState.new(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: nil
      )
      # before_create sets default, so we need to skip that
      mount_state.climb_progress = nil
      expect(mount_state.valid?).to be false
      expect(mount_state.errors[:climb_progress]).not_to be_empty
    end

    it 'validates mount_status is in MOUNT_STATUSES' do
      mount_state = MonsterMountState.new(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: 0,
        mount_status: 'invalid_status'
      )
      expect(mount_state.valid?).to be false
      expect(mount_state.errors[:mount_status]).not_to be_empty
    end

    %w[mounted climbing at_weak_point thrown dismounted].each do |status|
      it "accepts #{status} as mount_status" do
        mount_state = MonsterMountState.new(
          large_monster_instance_id: monster_instance.id,
          fight_participant_id: fight_participant.id,
          climb_progress: 0,
          mount_status: status
        )
        expect(mount_state.valid?).to be true
      end
    end

    it 'is valid with all required fields' do
      mount_state = MonsterMountState.new(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: 0,
        mount_status: 'mounted'
      )
      expect(mount_state.valid?).to be true
    end
  end

  describe '#before_create' do
    # Note: The model requires climb_progress for validation, so the before_create
    # default of ||= 0 doesn't apply (validation runs first). Testing that defaults
    # are preserved when nil values would be passed via factory.

    it 'sets default mount_status to mounted when nil' do
      mount_state = MonsterMountState.create(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: 0,
        mount_status: nil
      )
      expect(mount_state.mount_status).to eq('mounted')
    end

    it 'sets mounted_at timestamp' do
      mount_state = MonsterMountState.create(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: 0
      )
      expect(mount_state.mounted_at).not_to be_nil
    end

    it 'preserves explicitly set values' do
      mount_state = MonsterMountState.create(
        large_monster_instance_id: monster_instance.id,
        fight_participant_id: fight_participant.id,
        climb_progress: 3,
        mount_status: 'climbing'
      )
      expect(mount_state.climb_progress).to eq(3)
      expect(mount_state.mount_status).to eq('climbing')
    end
  end

  describe '#climb_distance' do
    it 'returns the climb distance from monster template' do
      mount_state = create(:monster_mount_state,
                           large_monster_instance: monster_instance,
                           fight_participant: fight_participant)
      expect(mount_state.climb_distance).to eq(5)
    end
  end

  describe '#at_weak_point?' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             climb_progress: 0,
             mount_status: 'mounted')
    end

    it 'returns true when mount_status is at_weak_point' do
      mount_state.update(mount_status: 'at_weak_point')
      expect(mount_state.at_weak_point?).to be true
    end

    it 'returns true when climb_progress >= climb_distance' do
      mount_state.update(climb_progress: 5)
      expect(mount_state.at_weak_point?).to be true
    end

    it 'returns true when climb_progress exceeds climb_distance' do
      mount_state.update(climb_progress: 7)
      expect(mount_state.at_weak_point?).to be true
    end

    it 'returns false when neither condition is met' do
      expect(mount_state.at_weak_point?).to be false
    end
  end

  describe '#advance_climb!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             climb_progress: 0,
             mount_status: 'mounted')
    end

    it 'increments climb_progress by 1' do
      result = mount_state.advance_climb!
      mount_state.refresh

      expect(mount_state.climb_progress).to eq(1)
      expect(result[:progress]).to eq(1)
    end

    it 'sets mount_status to climbing when not at weak point' do
      mount_state.advance_climb!
      mount_state.refresh

      expect(mount_state.mount_status).to eq('climbing')
    end

    it 'returns reached_weak_point: false when not at weak point' do
      result = mount_state.advance_climb!
      expect(result[:reached_weak_point]).to be false
    end

    context 'when reaching the weak point' do
      before do
        mount_state.update(climb_progress: 4) # One away from weak point
      end

      it 'sets mount_status to at_weak_point' do
        mount_state.advance_climb!
        mount_state.refresh

        expect(mount_state.mount_status).to eq('at_weak_point')
      end

      it 'returns reached_weak_point: true' do
        result = mount_state.advance_climb!
        expect(result[:reached_weak_point]).to be true
      end
    end
  end

  describe '#set_cling!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'climbing')
    end

    it 'sets mount_status to mounted' do
      mount_state.set_cling!
      mount_state.refresh

      expect(mount_state.mount_status).to eq('mounted')
    end

    it 'sets fight_participant mount_action to cling' do
      mount_state.set_cling!
      fight_participant.refresh

      expect(fight_participant.mount_action).to eq('cling')
    end
  end

  describe '#set_climbing!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'mounted')
    end

    it 'sets mount_status to climbing' do
      mount_state.set_climbing!
      mount_state.refresh

      expect(mount_state.mount_status).to eq('climbing')
    end

    it 'sets fight_participant mount_action to climb' do
      mount_state.set_climbing!
      fight_participant.refresh

      expect(fight_participant.mount_action).to eq('climb')
    end
  end

  describe '#mount_action_is_cling?' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant)
    end

    it 'returns true when mount_action is cling' do
      fight_participant.update(mount_action: 'cling')
      expect(mount_state.mount_action_is_cling?).to be true
    end

    it 'returns false when mount_action is not cling' do
      fight_participant.update(mount_action: 'climb')
      expect(mount_state.mount_action_is_cling?).to be false
    end

    it 'returns false when mount_action is nil' do
      fight_participant.update(mount_action: nil)
      expect(mount_state.mount_action_is_cling?).to be false
    end
  end

  describe '#throw_off!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'climbing',
             climb_progress: 3)
    end

    it 'sets mount_status to thrown' do
      mount_state.throw_off!(2, 4)
      mount_state.refresh

      expect(mount_state.mount_status).to eq('thrown')
    end

    it 'resets climb_progress to 0' do
      mount_state.throw_off!(2, 4)
      mount_state.refresh

      expect(mount_state.climb_progress).to eq(0)
    end

    it 'stores scatter hex coordinates' do
      mount_state.throw_off!(2, 4)
      mount_state.refresh

      expect(mount_state.scatter_hex_x).to eq(2)
      expect(mount_state.scatter_hex_y).to eq(4)
    end

    it 'updates participant is_mounted to false' do
      fight_participant.update(is_mounted: true)
      mount_state.throw_off!(2, 4)
      fight_participant.refresh

      expect(fight_participant.is_mounted).to be false
    end

    it 'clears participant mount_action' do
      fight_participant.update(mount_action: 'climb')
      mount_state.throw_off!(2, 4)
      fight_participant.refresh

      expect(fight_participant.mount_action).to be_nil
    end
  end

  describe '#dismount!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'mounted',
             climb_progress: 3)
    end

    before do
      fight_participant.update(is_mounted: true, mount_action: 'cling')
    end

    it 'sets mount_status to dismounted' do
      mount_state.dismount!(3, 5)
      mount_state.refresh

      expect(mount_state.mount_status).to eq('dismounted')
    end

    it 'stores scatter hex coordinates' do
      mount_state.dismount!(3, 5)
      mount_state.refresh

      expect(mount_state.scatter_hex_x).to eq(3)
      expect(mount_state.scatter_hex_y).to eq(5)
    end

    it 'updates participant is_mounted to false' do
      mount_state.dismount!(3, 5)
      fight_participant.refresh

      expect(fight_participant.is_mounted).to be false
    end

    it 'clears participant mount_action' do
      mount_state.dismount!(3, 5)
      fight_participant.refresh

      expect(fight_participant.mount_action).to be_nil
    end

    it 'updates participant hex position' do
      mount_state.dismount!(3, 5)
      fight_participant.refresh

      expect(fight_participant.hex_x).to eq(3)
      expect(fight_participant.hex_y).to eq(5)
    end
  end

  describe '#apply_throw!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'thrown',
             scatter_hex_x: 7,
             scatter_hex_y: 8)
    end

    it 'updates participant hex position to scatter coordinates' do
      mount_state.apply_throw!
      fight_participant.refresh

      expect(fight_participant.hex_x).to eq(7)
      expect(fight_participant.hex_y).to eq(8)
    end

    it 'sets mount_status to dismounted' do
      mount_state.apply_throw!
      mount_state.refresh

      expect(mount_state.mount_status).to eq('dismounted')
    end

    it 'does nothing if mount_status is not thrown' do
      mount_state.update(mount_status: 'climbing')
      original_x = fight_participant.hex_x
      original_y = fight_participant.hex_y

      mount_state.apply_throw!
      fight_participant.refresh

      expect(fight_participant.hex_x).to eq(original_x)
      expect(fight_participant.hex_y).to eq(original_y)
    end

    it 'does nothing if scatter coordinates are nil' do
      mount_state.update(scatter_hex_x: nil, scatter_hex_y: nil)
      original_status = mount_state.mount_status

      mount_state.apply_throw!
      mount_state.refresh

      expect(mount_state.mount_status).to eq(original_status)
    end
  end

  describe '#fling_after_weak_point_attack!' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             mount_status: 'at_weak_point',
             climb_progress: 5)
    end

    before do
      fight_participant.update(is_mounted: true, mount_action: 'attack')
    end

    it 'sets mount_status to dismounted' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      mount_state.refresh

      expect(mount_state.mount_status).to eq('dismounted')
    end

    it 'resets climb_progress to 0' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      mount_state.refresh

      expect(mount_state.climb_progress).to eq(0)
    end

    it 'stores scatter hex coordinates' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      mount_state.refresh

      expect(mount_state.scatter_hex_x).to eq(4)
      expect(mount_state.scatter_hex_y).to eq(6)
    end

    it 'updates participant is_mounted to false' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      fight_participant.refresh

      expect(fight_participant.is_mounted).to be false
    end

    it 'clears participant mount_action' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      fight_participant.refresh

      expect(fight_participant.mount_action).to be_nil
    end

    it 'updates participant hex position' do
      mount_state.fling_after_weak_point_attack!(4, 6)
      fight_participant.refresh

      expect(fight_participant.hex_x).to eq(4)
      expect(fight_participant.hex_y).to eq(6)
    end
  end

  describe '#display_info' do
    let(:mount_state) do
      create(:monster_mount_state,
             large_monster_instance: monster_instance,
             fight_participant: fight_participant,
             climb_progress: 3,
             mount_status: 'climbing')
    end

    it 'returns hash with all display fields' do
      info = mount_state.display_info

      expect(info[:participant_name]).to eq(fight_participant.character_name)
      expect(info[:monster_name]).to eq(monster_instance.display_name)
      expect(info[:climb_progress]).to eq(3)
      expect(info[:climb_distance]).to eq(5)
      expect(info[:at_weak_point]).to be false
      expect(info[:mount_status]).to eq('climbing')
    end

    it 'returns at_weak_point: true when at weak point' do
      mount_state.update(mount_status: 'at_weak_point', climb_progress: 5)
      info = mount_state.display_info

      expect(info[:at_weak_point]).to be true
    end
  end
end
