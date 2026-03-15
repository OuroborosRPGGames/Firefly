# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TravelPartyMember do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality)
  end
  let(:destination) { create(:location) }
  let(:party) do
    TravelParty.create(
      leader_id: character_instance.id,
      destination_id: destination.id,
      origin_room_id: room.id,
      status: 'assembling'
    )
  end
  let(:member) do
    described_class.create(
      party_id: party.id,
      character_instance_id: character_instance.id,
      status: 'pending'
    )
  end

  describe '#accept!' do
    it 'returns false if status is not pending' do
      member.update(status: 'accepted')
      expect(member.accept!).to be false
    end

    it 'returns false if party is not assembling' do
      party.update(status: 'departed')
      expect(member.accept!).to be false
    end

    it 'updates status to accepted and sets responded_at' do
      expect(member.accept!).to be true
      member.refresh
      expect(member.status).to eq('accepted')
      expect(member.responded_at).not_to be_nil
    end
  end

  describe '#decline!' do
    it 'returns false if status is not pending' do
      member.update(status: 'accepted')
      expect(member.decline!).to be false
    end

    it 'returns false if party is not assembling' do
      party.update(status: 'departed')
      expect(member.decline!).to be false
    end

    it 'updates status to declined and sets responded_at' do
      expect(member.decline!).to be true
      member.refresh
      expect(member.status).to eq('declined')
      expect(member.responded_at).not_to be_nil
    end
  end

  describe '#leader?' do
    it 'returns true when member is the party leader' do
      expect(member.leader?).to be true
    end

    it 'returns false when member is not the leader' do
      other_instance = create(:character_instance, current_room: room, reality: reality)
      other_member = described_class.create(party_id: party.id, character_instance_id: other_instance.id)
      expect(other_member.leader?).to be false
    end
  end

  describe '#pending?' do
    it 'returns true when status is pending' do
      expect(member.pending?).to be true
    end

    it 'returns false when status is not pending' do
      member.update(status: 'accepted')
      expect(member.pending?).to be false
    end
  end

  describe '#accepted?' do
    it 'returns true when status is accepted' do
      member.update(status: 'accepted')
      expect(member.accepted?).to be true
    end

    it 'returns false when status is not accepted' do
      expect(member.accepted?).to be false
    end
  end

  describe '#declined?' do
    it 'returns true when status is declined' do
      member.update(status: 'declined')
      expect(member.declined?).to be true
    end

    it 'returns false when status is not declined' do
      expect(member.declined?).to be false
    end
  end

  describe '#display_status' do
    it 'returns Invited for pending' do
      expect(member.display_status).to eq('Invited')
    end

    it 'returns Ready for accepted' do
      member.update(status: 'accepted')
      expect(member.display_status).to eq('Ready')
    end

    it 'returns Declined for declined' do
      member.update(status: 'declined')
      expect(member.display_status).to eq('Declined')
    end
  end
end
