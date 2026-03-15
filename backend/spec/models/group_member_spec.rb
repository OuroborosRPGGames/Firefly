# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GroupMember do
  let(:group) { create(:group) }
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to group' do
      member = create(:group_member, group: group, character: character)
      expect(member.group.id).to eq(group.id)
    end

    it 'belongs to character' do
      member = create(:group_member, group: group, character: character)
      expect(member.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'requires group_id' do
      member = GroupMember.new(character_id: character.id)
      expect(member.valid?).to be false
      expect(member.errors[:group_id]).not_to be_empty
    end

    it 'requires character_id' do
      member = GroupMember.new(group_id: group.id)
      expect(member.valid?).to be false
      expect(member.errors[:character_id]).not_to be_empty
    end

    it 'validates uniqueness of group_id and character_id' do
      create(:group_member, group: group, character: character)

      duplicate = GroupMember.new(group_id: group.id, character_id: character.id)
      expect(duplicate.valid?).to be false
    end

    %w[member officer leader].each do |rank|
      it "accepts #{rank} as rank" do
        member = GroupMember.new(group_id: group.id, character_id: character.id, rank: rank)
        expect(member.valid?).to be true
      end
    end

    it 'rejects invalid rank' do
      member = GroupMember.new(group_id: group.id, character_id: character.id, rank: 'invalid')
      expect(member.valid?).to be false
    end

    %w[active inactive suspended removed].each do |status|
      it "accepts #{status} as status" do
        member = GroupMember.new(group_id: group.id, character_id: character.id, status: status)
        expect(member.valid?).to be true
      end
    end

    it 'rejects invalid status' do
      member = GroupMember.new(group_id: group.id, character_id: character.id, status: 'invalid')
      expect(member.valid?).to be false
    end

    it 'validates handle length' do
      member = GroupMember.new(
        group_id: group.id,
        character_id: character.id,
        handle: 'a' * 51
      )
      expect(member.valid?).to be false
      expect(member.errors[:handle]).not_to be_empty
    end

    it 'validates handle uniqueness within group' do
      create(:group_member, group: group, character: character, handle: 'Alpha')

      other_character = create(:character)
      member = GroupMember.new(
        group_id: group.id,
        character_id: other_character.id,
        handle: 'Alpha'
      )
      expect(member.valid?).to be false
      expect(member.errors[:handle]).not_to be_empty
    end

    it 'allows same handle in different groups' do
      create(:group_member, group: group, character: character, handle: 'Alpha')

      other_group = create(:group)
      member = GroupMember.new(
        group_id: other_group.id,
        character_id: character.id,
        handle: 'Alpha'
      )
      expect(member.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'sets default rank to member' do
      member = create(:group_member, group: group, character: character, rank: nil)
      expect(member.rank).to eq('member')
    end

    it 'sets default status to active' do
      member = create(:group_member, group: group, character: character, status: nil)
      expect(member.status).to eq('active')
    end

    it 'sets joined_at if not provided' do
      member = create(:group_member, group: group, character: character, joined_at: nil)
      expect(member.joined_at).not_to be_nil
    end
  end

  describe '#active?' do
    it 'returns true when status is active' do
      member = create(:group_member, group: group, character: character, status: 'active')
      expect(member.active?).to be true
    end

    it 'returns false when status is not active' do
      member = create(:group_member, group: group, character: character, status: 'suspended')
      expect(member.active?).to be false
    end
  end

  describe '#leader?' do
    it 'returns true when rank is leader' do
      member = create(:group_member, :leader, group: group, character: character)
      expect(member.leader?).to be true
    end

    it 'returns true when character is group leader' do
      group.update(leader_character_id: character.id)
      member = create(:group_member, group: group, character: character, rank: 'member')
      expect(member.leader?).to be true
    end

    it 'returns false for regular members' do
      member = create(:group_member, group: group, character: character, rank: 'member')
      expect(member.leader?).to be false
    end
  end

  describe '#officer?' do
    it 'returns true when rank is officer' do
      member = create(:group_member, :officer, group: group, character: character)
      expect(member.officer?).to be true
    end

    it 'returns true when rank is leader' do
      member = create(:group_member, :leader, group: group, character: character)
      expect(member.officer?).to be true
    end

    it 'returns false for regular members' do
      member = create(:group_member, group: group, character: character, rank: 'member')
      expect(member.officer?).to be false
    end
  end

  describe '#can_invite?' do
    it 'returns true for officers' do
      member = create(:group_member, :officer, group: group, character: character)
      expect(member.can_invite?).to be true
    end

    it 'returns false for regular members' do
      member = create(:group_member, group: group, character: character)
      expect(member.can_invite?).to be false
    end
  end

  describe '#can_kick?' do
    it 'returns true for officers' do
      member = create(:group_member, :officer, group: group, character: character)
      expect(member.can_kick?).to be true
    end

    it 'returns false for regular members' do
      member = create(:group_member, group: group, character: character)
      expect(member.can_kick?).to be false
    end
  end

  describe '#promote!' do
    let(:member) { create(:group_member, group: group, character: character, rank: 'member') }

    it 'updates rank' do
      member.promote!('officer')
      member.refresh

      expect(member.rank).to eq('officer')
    end
  end

  describe '#suspend!' do
    let(:member) { create(:group_member, group: group, character: character, status: 'active') }

    it 'sets status to suspended' do
      member.suspend!
      member.refresh

      expect(member.status).to eq('suspended')
    end
  end

  describe '#reinstate!' do
    let(:member) { create(:group_member, group: group, character: character, status: 'suspended') }

    it 'sets status to active' do
      member.reinstate!
      member.refresh

      expect(member.status).to eq('active')
    end
  end

  describe '#display_name_for' do
    context 'in a public group' do
      let(:public_group) { create(:group, is_secret: false) }
      let(:member) { create(:group_member, group: public_group, character: character) }

      it 'returns the character full name' do
        expect(member.display_name_for(nil)).to eq(character.full_name)
      end
    end

    context 'in a secret group' do
      let(:secret_group) { create(:group, :secret) }

      it 'returns the handle if set' do
        member = create(:group_member, group: secret_group, character: character, handle: 'Shadow')
        expect(member.display_name_for(nil)).to eq('Shadow')
      end

      it 'returns default greek handle if no handle set' do
        member = create(:group_member, group: secret_group, character: character, handle: nil)
        expect(member.display_name_for(nil)).to eq('Alpha')
      end
    end
  end

  describe '#default_greek_handle' do
    let(:secret_group) { create(:group, :secret) }

    it 'returns Greek letter based on join order' do
      first_member = create(:group_member, group: secret_group, character: character, joined_at: Time.now - 120)
      second_char = create(:character)
      second_member = create(:group_member, group: secret_group, character: second_char, joined_at: Time.now - 60)

      expect(first_member.default_greek_handle).to eq('Alpha')
      expect(second_member.default_greek_handle).to eq('Beta')
    end

    it 'wraps around for more than 24 members' do
      # Create 24 members to use all Greek letters
      24.times do |i|
        char = create(:character)
        create(:group_member, group: secret_group, character: char, joined_at: Time.now - (100 - i))
      end

      # 25th member should wrap to Alpha
      member = create(:group_member, group: secret_group, character: character, joined_at: Time.now)
      expect(member.default_greek_handle).to eq('Alpha')
    end
  end
end
