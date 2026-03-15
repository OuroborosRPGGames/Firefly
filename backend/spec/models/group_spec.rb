# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Group do
  let(:universe) { create(:universe) }
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:other_user) { create(:user) }
  let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

  describe 'validations' do
    it 'requires name' do
      group = Group.new(universe_id: universe.id, group_type: 'faction')
      expect(group.valid?).to be false
      expect(group.errors[:name]).not_to be_empty
    end

    it 'requires group_type' do
      group = Group.new(universe_id: universe.id, name: 'Test')
      group.group_type = nil
      expect(group.valid?).to be false
      expect(group.errors[:group_type]).not_to be_empty
    end

    it 'validates group_type is in allowed list' do
      group = Group.new(universe_id: universe.id, name: 'Test', group_type: 'invalid')
      expect(group.valid?).to be false
    end

    it 'validates status is in allowed list' do
      group = Group.create(universe_id: universe.id, name: 'Test', group_type: 'faction')
      group.status = 'invalid'
      expect(group.valid?).to be false
    end

    it 'validates name is unique within universe' do
      Group.create(universe_id: universe.id, name: 'Unique Name', group_type: 'faction')
      duplicate = Group.new(universe_id: universe.id, name: 'Unique Name', group_type: 'guild')
      expect(duplicate.valid?).to be false
    end

    it 'allows same name in different universes' do
      other_universe = create(:universe)
      Group.create(universe_id: universe.id, name: 'Shared Name', group_type: 'faction')
      other_group = Group.new(universe_id: other_universe.id, name: 'Shared Name', group_type: 'faction')
      expect(other_group.valid?).to be true
    end
  end

  describe 'defaults' do
    it 'sets default status to active' do
      group = Group.create(universe_id: universe.id, name: 'Test', group_type: 'guild')
      expect(group.status).to eq('active')
    end

    it 'sets founded_at on create' do
      group = Group.create(universe_id: universe.id, name: 'Test', group_type: 'faction')
      expect(group.founded_at).not_to be_nil
    end
  end

  describe 'visibility methods' do
    let(:group) { Group.create(universe_id: universe.id, name: 'Test', group_type: 'faction') }

    describe '#secret?' do
      it 'returns false by default' do
        expect(group.secret?).to be false
      end

      it 'returns true when is_secret is true' do
        group.update(is_secret: true)
        expect(group.secret?).to be true
      end
    end

    describe '#public_listing?' do
      it 'returns true when public and not secret' do
        group.update(is_public: true, is_secret: false)
        expect(group.public_listing?).to be true
      end

      it 'returns false when secret' do
        group.update(is_public: true, is_secret: true)
        expect(group.public_listing?).to be false
      end
    end
  end

  describe 'member management' do
    let!(:group) { Group.create(universe_id: universe.id, name: 'Test Guild', group_type: 'guild') }

    describe '#add_member' do
      it 'adds a character to the group' do
        group.add_member(character)
        expect(group.member?(character)).to be true
      end

      it 'sets default rank to member' do
        membership = group.add_member(character)
        expect(membership.rank).to eq('member')
      end

      it 'can set custom rank' do
        membership = group.add_member(character, rank: 'officer')
        expect(membership.rank).to eq('officer')
      end

      it 'can set handle for secret groups' do
        membership = group.add_member(character, handle: 'ShadowAgent')
        expect(membership.handle).to eq('ShadowAgent')
      end
    end

    describe '#remove_member' do
      before { group.add_member(character) }

      it 'removes member from group' do
        group.remove_member(character)
        expect(group.member?(character)).to be false
      end
    end

    describe '#member?' do
      it 'returns false for non-member' do
        expect(group.member?(character)).to be false
      end

      it 'returns true for active member' do
        group.add_member(character)
        expect(group.member?(character)).to be true
      end

      it 'returns false for nil character' do
        expect(group.member?(nil)).to be false
      end
    end

    describe '#member_count' do
      it 'returns count of active members' do
        group.add_member(character)
        group.add_member(other_character)
        expect(group.member_count).to eq(2)
      end

      it 'returns 0 for empty group' do
        expect(group.member_count).to eq(0)
      end
    end

    describe '#membership_for' do
      it 'returns membership for member' do
        group.add_member(character)
        membership = group.membership_for(character)
        expect(membership).not_to be_nil
        expect(membership.character_id).to eq(character.id)
      end

      it 'returns nil for non-member' do
        expect(group.membership_for(character)).to be_nil
      end
    end

    describe '#leader?' do
      it 'returns true for group leader' do
        group.update(leader_character_id: character.id)
        expect(group.leader?(character)).to be true
      end

      it 'returns false for non-leader' do
        expect(group.leader?(character)).to be false
      end
    end
  end

  describe 'room access' do
    let!(:group) { Group.create(universe_id: universe.id, name: 'Test Guild', group_type: 'guild') }

    describe '#grant_room_access!' do
      it 'grants access to a room' do
        group.grant_room_access!(room)
        expect(group.has_room_access?(room)).to be true
      end

      it 'can grant permanent access' do
        unlock = group.grant_room_access!(room, permanent: true)
        expect(unlock.expires_at).to be_nil
      end
    end

    describe '#revoke_room_access!' do
      before { group.grant_room_access!(room) }

      it 'removes room access' do
        group.revoke_room_access!(room)
        expect(group.has_room_access?(room)).to be false
      end
    end

    describe '#has_room_access?' do
      it 'returns false when no access granted' do
        expect(group.has_room_access?(room)).to be false
      end
    end
  end

  describe '#display_name' do
    let!(:group) { Group.create(universe_id: universe.id, name: 'Test Guild', group_type: 'guild') }

    it 'returns name when no symbol' do
      expect(group.display_name).to eq('Test Guild')
    end

    it 'includes symbol when present' do
      group.update(symbol: '[TG]')
      expect(group.display_name).to eq('[TG] Test Guild')
    end
  end

  describe 'constants' do
    it 'defines valid group types' do
      expect(Group::GROUP_TYPES).to include('faction', 'guild', 'party', 'clan')
    end

    it 'defines valid statuses' do
      expect(Group::STATUSES).to include('active', 'inactive', 'disbanded')
    end
  end
end
