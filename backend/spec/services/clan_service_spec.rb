# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClanService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:universe) { create(:universe) }

  before do
    allow(character).to receive(:universe_id).and_return(universe.id)
  end

  describe '.create_clan' do
    context 'with valid parameters' do
      it 'creates a clan successfully' do
        result = described_class.create_clan(character, name: 'Test Clan')

        expect(result[:success]).to be true
        expect(result[:clan]).to be_a(Group)
        expect(result[:clan].name).to eq('Test Clan')
      end

      it 'sets the creator as leader' do
        result = described_class.create_clan(character, name: 'Test Clan')

        expect(result[:clan].leader_character_id).to eq(character.id)
      end

      it 'creates a channel when create_channel is true' do
        result = described_class.create_clan(character, name: 'Test Clan', create_channel: true)

        expect(result[:clan].channel).not_to be_nil
      end

      it 'does not create a channel when create_channel is false' do
        result = described_class.create_clan(character, name: 'Test Clan', create_channel: false)

        expect(result[:clan].channel).to be_nil
      end

      it 'sets secret flag correctly' do
        result = described_class.create_clan(character, name: 'Secret Clan', secret: true)

        expect(result[:clan].is_secret).to be true
        expect(result[:clan].is_public).to be false
      end

      it 'sets the clan symbol' do
        result = described_class.create_clan(character, name: 'Test Clan', symbol: '†')

        expect(result[:clan].symbol).to eq('†')
      end
    end

    context 'with invalid parameters' do
      it 'returns error when name is nil' do
        result = described_class.create_clan(character, name: nil)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Name is required')
      end

      it 'returns error when name is empty' do
        result = described_class.create_clan(character, name: '   ')

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Name is required')
      end

      it 'returns error when name is too long' do
        result = described_class.create_clan(character, name: 'a' * 101)

        expect(result[:success]).to be false
        expect(result[:error]).to include('too long')
      end

      it 'returns error when clan with same name exists' do
        described_class.create_clan(character, name: 'Existing Clan')
        result = described_class.create_clan(character, name: 'Existing Clan')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already exists')
      end
    end
  end

  describe '.invite_member' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan')[:clan] }
    let(:target_user) { create(:user) }
    let(:target_character) { create(:character, user: target_user) }

    context 'with valid permissions' do
      it 'adds a new member to the clan' do
        result = described_class.invite_member(clan, character, target_character)

        expect(result[:success]).to be true
        expect(clan.member?(target_character)).to be true
      end

      it 'allows setting a handle for the new member' do
        result = described_class.invite_member(clan, character, target_character, handle: 'NewGuy')

        expect(result[:success]).to be true
        membership = clan.membership_for(target_character)
        expect(membership.handle).to eq('NewGuy')
      end
    end

    context 'without valid permissions' do
      let(:non_member_user) { create(:user) }
      let(:non_member) { create(:character, user: non_member_user) }

      it 'returns error when inviter is not a member' do
        result = described_class.invite_member(clan, non_member, target_character)

        expect(result[:success]).to be false
        expect(result[:error]).to include('not a member')
      end

      it 'returns error when target is already a member' do
        described_class.invite_member(clan, character, target_character)
        result = described_class.invite_member(clan, character, target_character)

        expect(result[:success]).to be false
        expect(result[:error]).to include('already a member')
      end
    end
  end

  describe '.kick_member' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan')[:clan] }
    let(:member_user) { create(:user) }
    let(:member_character) { create(:character, user: member_user) }

    before do
      described_class.invite_member(clan, character, member_character)
    end

    it 'removes a member from the clan' do
      result = described_class.kick_member(clan, character, member_character)

      expect(result[:success]).to be true
      expect(clan.member?(member_character)).to be false
    end

    it 'returns error when kicker is not a member' do
      non_member = create(:character)
      result = described_class.kick_member(clan, non_member, member_character)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not a member')
    end

    it 'returns error when trying to kick the leader' do
      result = described_class.kick_member(clan, character, character)

      expect(result[:success]).to be false
      expect(result[:error]).to include('cannot kick the clan leader')
    end

    it 'returns error when target is not a member' do
      non_member = create(:character)
      result = described_class.kick_member(clan, character, non_member)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not a member')
    end
  end

  describe '.leave_clan' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan')[:clan] }
    let(:member_user) { create(:user) }
    let(:member_character) { create(:character, user: member_user) }

    before do
      described_class.invite_member(clan, character, member_character)
    end

    it 'allows a member to leave the clan' do
      result = described_class.leave_clan(clan, member_character)

      expect(result[:success]).to be true
      expect(clan.member?(member_character)).to be false
    end

    it 'returns error when the leader tries to leave' do
      result = described_class.leave_clan(clan, character)

      expect(result[:success]).to be false
      expect(result[:error]).to include('leader cannot leave')
    end

    it 'returns error when non-member tries to leave' do
      non_member = create(:character)
      result = described_class.leave_clan(clan, non_member)

      expect(result[:success]).to be false
      expect(result[:error]).to include('not a member')
    end
  end

  describe '.set_handle' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan')[:clan] }

    it 'sets a new handle for the member' do
      result = described_class.set_handle(clan, character, 'NewHandle')

      expect(result[:success]).to be true
      membership = clan.membership_for(character)
      expect(membership.handle).to eq('NewHandle')
    end

    it 'returns error when non-member tries to set handle' do
      non_member = create(:character)
      result = described_class.set_handle(clan, non_member, 'Handle')

      expect(result[:success]).to be false
      expect(result[:error]).to include('not a member')
    end

    it 'returns error when handle is too long' do
      result = described_class.set_handle(clan, character, 'a' * 51)

      expect(result[:success]).to be false
      expect(result[:error]).to include('too long')
    end
  end

  describe '.list_clans_for' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user) }

    before do
      allow(other_character).to receive(:universe_id).and_return(universe.id)
    end

    it 'returns public clans' do
      described_class.create_clan(character, name: 'Public Clan')
      clans = described_class.list_clans_for(other_character)

      expect(clans.map(&:name)).to include('Public Clan')
    end

    it 'returns clans the character is a member of' do
      clan = described_class.create_clan(character, name: 'Test Clan', secret: true)[:clan]
      described_class.invite_member(clan, character, other_character)

      clans = described_class.list_clans_for(other_character)
      expect(clans.map(&:name)).to include('Test Clan')
    end

    it 'does not return secret clans the character is not in' do
      described_class.create_clan(character, name: 'Secret Clan', secret: true)

      clans = described_class.list_clans_for(other_character)
      expect(clans.map(&:name)).not_to include('Secret Clan')
    end
  end

  describe '.find_clan_by_name' do
    before do
      allow(character).to receive(:universe_id).and_return(universe.id)
      described_class.create_clan(character, name: 'Test Clan')
    end

    it 'finds a clan by exact name (case insensitive)' do
      clan = described_class.find_clan_by_name('test clan')

      expect(clan).not_to be_nil
      expect(clan.name).to eq('Test Clan')
    end

    it 'returns nil when clan not found' do
      clan = described_class.find_clan_by_name('Nonexistent')

      expect(clan).to be_nil
    end
  end

  describe '.find_clan_by_name_prefix' do
    before do
      allow(character).to receive(:universe_id).and_return(universe.id)
      described_class.create_clan(character, name: 'Shadowhunters')
    end

    it 'finds a clan by exact name first' do
      clan = described_class.find_clan_by_name_prefix('Shadowhunters')

      expect(clan).not_to be_nil
      expect(clan.name).to eq('Shadowhunters')
    end

    it 'finds a clan by prefix match' do
      clan = described_class.find_clan_by_name_prefix('Shadow')

      expect(clan).not_to be_nil
      expect(clan.name).to eq('Shadowhunters')
    end

    it 'returns nil for short prefixes' do
      clan = described_class.find_clan_by_name_prefix('S')

      expect(clan).to be_nil
    end

    it 'returns nil when not found' do
      clan = described_class.find_clan_by_name_prefix('Nonexistent')

      expect(clan).to be_nil
    end
  end

  describe '.broadcast_to_clan' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan', create_channel: true)[:clan] }
    let(:instance) { create(:character_instance, character: character) }

    it 'returns error when clan has no channel' do
      clan_without_channel = described_class.create_clan(character, name: 'No Channel', create_channel: false)[:clan]
      result = described_class.broadcast_to_clan(clan_without_channel, instance, 'Hello')

      expect(result[:success]).to be false
      expect(result[:error]).to include("doesn't have a chat channel")
    end
  end

  describe '.send_clan_memo' do
    let(:clan) { described_class.create_clan(character, name: 'Test Clan')[:clan] }
    let(:member_user) { create(:user) }
    let(:member_character) { create(:character, user: member_user) }

    before do
      described_class.invite_member(clan, character, member_character)
    end

    it 'sends memos to all clan members' do
      result = described_class.send_clan_memo(clan, character, subject: 'Test', body: 'Message')

      expect(result[:success]).to be true
      expect(result[:count]).to eq(1) # Only to member, not sender
    end

    it 'returns error when sender is not a member' do
      non_member = create(:character)
      result = described_class.send_clan_memo(clan, non_member, subject: 'Test', body: 'Message')

      expect(result[:success]).to be false
      expect(result[:error]).to include('not a member')
    end
  end
end
