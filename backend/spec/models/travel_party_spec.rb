# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TravelParty do
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character) }
  let(:location) { create(:location) }
  let(:room) { create(:room) }

  before do
    allow(character_instance).to receive(:current_room).and_return(room)
    allow(character_instance).to receive(:current_room_id).and_return(room.id)
  end

  describe 'constants' do
    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[assembling departed cancelled])
    end
  end

  describe '.create_for' do
    it 'creates a party with the character as leader' do
      party = described_class.create_for(character_instance, location)

      expect(party.id).not_to be_nil
      expect(party.leader_id).to eq(character_instance.id)
      expect(party.destination_id).to eq(location.id)
      expect(party.status).to eq('assembling')
    end

    it 'adds the leader as first accepted member' do
      party = described_class.create_for(character_instance, location)

      expect(party.members.count).to eq(1)
      expect(party.members.first.character_instance_id).to eq(character_instance.id)
      expect(party.members.first.status).to eq('accepted')
    end

    it 'sets the origin room' do
      party = described_class.create_for(character_instance, location)
      expect(party.origin_room_id).to eq(room.id)
    end

    it 'accepts travel_mode option' do
      party = described_class.create_for(character_instance, location, travel_mode: 'land')
      expect(party.travel_mode).to eq('land')
    end

    it 'accepts flashback_mode option' do
      party = described_class.create_for(character_instance, location, flashback_mode: true)
      # Column is varchar, so value is stored as string "true"
      expect(party.flashback_mode).to be_truthy
    end
  end

  describe '#invite!' do
    let(:party) { described_class.create_for(character_instance, location) }
    let(:other_character) { create(:character) }
    let(:other_instance) { create(:character_instance, character: other_character) }

    before do
      allow(BroadcastService).to receive(:to_character)
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'adds a member with pending status' do
      result = party.invite!(other_instance)

      expect(result[:success]).to be true
      expect(result[:member].status).to eq('pending')
    end

    it 'returns error when already a member' do
      party.invite!(other_instance)
      result = party.invite!(other_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to include('Already a member')
    end

    it 'returns error when party is not assembling' do
      party.update(status: 'departed')
      result = party.invite!(other_instance)

      expect(result[:success]).to be false
      expect(result[:error]).to include('no longer assembling')
    end

    it 'sends party invite notification' do
      party.invite!(other_instance)

      expect(BroadcastService).to have_received(:to_character)
    end
  end

  describe '#member?' do
    let(:party) { described_class.create_for(character_instance, location) }
    let(:other_instance) { create(:character_instance, character: create(:character)) }

    it 'returns true for leader' do
      expect(party.member?(character_instance)).to be true
    end

    it 'returns false for non-member' do
      expect(party.member?(other_instance)).to be false
    end

    it 'returns true for invited member' do
      allow(BroadcastService).to receive(:to_character)
      allow(OutputHelper).to receive(:store_agent_interaction)
      party.invite!(other_instance)

      expect(party.member?(other_instance)).to be true
    end
  end

  describe '#membership_for' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'returns membership record for member' do
      membership = party.membership_for(character_instance)
      expect(membership).not_to be_nil
      expect(membership.character_instance_id).to eq(character_instance.id)
    end

    it 'returns nil for non-member' do
      other_instance = create(:character_instance, character: create(:character))
      expect(party.membership_for(other_instance)).to be_nil
    end
  end

  describe '#remove_member!' do
    let(:party) { described_class.create_for(character_instance, location) }
    let(:other_instance) { create(:character_instance, character: create(:character)) }

    before do
      allow(BroadcastService).to receive(:to_character)
      allow(OutputHelper).to receive(:store_agent_interaction)
      party.invite!(other_instance)
    end

    it 'removes invited member' do
      party.remove_member!(other_instance)
      expect(party.member?(other_instance)).to be false
    end

    it 'does not remove the leader' do
      party.remove_member!(character_instance)
      expect(party.member?(character_instance)).to be true
    end
  end

  describe '#accepted_members' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'returns only accepted members' do
      accepted = party.accepted_members
      expect(accepted.count).to eq(1)
      expect(accepted.first.status).to eq('accepted')
    end
  end

  describe '#pending_invites' do
    let(:party) { described_class.create_for(character_instance, location) }
    let(:other_instance) { create(:character_instance, character: create(:character)) }

    before do
      allow(BroadcastService).to receive(:to_character)
      allow(OutputHelper).to receive(:store_agent_interaction)
    end

    it 'returns pending invitations' do
      party.invite!(other_instance)

      pending = party.pending_invites
      expect(pending.count).to eq(1)
      expect(pending.first.status).to eq('pending')
    end
  end

  describe '#can_launch?' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'returns true when assembling with accepted members' do
      expect(party.can_launch?).to be true
    end

    it 'returns false when status is not assembling' do
      party.update(status: 'cancelled')
      expect(party.can_launch?).to be false
    end
  end

  describe '#minimum_flashback_time' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'returns minimum flashback time among accepted members' do
      # Stub the method directly to return a mock with flashback_time_available
      mock_instance = double('CharacterInstance', flashback_time_available: 3600)
      allow(party).to receive(:accepted_character_instances).and_return([mock_instance])

      expect(party.minimum_flashback_time).to eq(3600)
    end
  end

  describe '#cancel!' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'sets status to cancelled' do
      party.cancel!
      expect(party.status).to eq('cancelled')
    end
  end

  describe '#launch!' do
    let(:party) { described_class.create_for(character_instance, location) }

    context 'when cannot launch' do
      before { party.update(status: 'cancelled') }

      it 'returns error' do
        result = party.launch!
        expect(result[:success]).to be false
        expect(result[:error]).to include('cannot launch')
      end
    end

    context 'when can launch' do
      before do
        allow(JourneyService).to receive(:start_party_journey).and_return({ success: true })
      end

      it 'starts the journey and updates status' do
        result = party.launch!

        expect(result[:success]).to be true
        expect(party.reload.status).to eq('departed')
      end

      it 'calls JourneyService with correct parameters' do
        party.launch!

        expect(JourneyService).to have_received(:start_party_journey).with(
          hash_including(
            destination: location,
            travel_mode: party.travel_mode,
            flashback_mode: party.flashback_mode
          )
        )
      end
    end
  end

  describe '#status_summary' do
    let(:party) { described_class.create_for(character_instance, location) }

    before do
      allow(character_instance).to receive(:flashback_time_available).and_return(3600)
    end

    it 'returns a summary hash' do
      summary = party.status_summary

      expect(summary[:id]).to eq(party.id)
      expect(summary[:status]).to eq('assembling')
      expect(summary[:destination]).to be_a(Hash)
      expect(summary[:destination][:name]).to eq(location.name)
      expect(summary[:accepted_count]).to eq(1)
      expect(summary[:pending_count]).to eq(0)
      expect(summary[:can_launch]).to be true
    end

    it 'includes member information' do
      summary = party.status_summary

      expect(summary[:members]).to be_an(Array)
      expect(summary[:members].first[:status]).to eq('accepted')
    end
  end

  describe 'associations' do
    let(:party) { described_class.create_for(character_instance, location) }

    it 'belongs to leader' do
      expect(party.leader).to eq(character_instance)
    end

    it 'belongs to destination' do
      expect(party.destination).to eq(location)
    end

    it 'belongs to origin_room' do
      expect(party.origin_room).to eq(room)
    end

    it 'has many members' do
      expect(party.members).not_to be_empty
    end
  end
end
