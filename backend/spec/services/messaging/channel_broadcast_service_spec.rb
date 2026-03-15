# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChannelBroadcastService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:sender_character) { create(:character, forename: 'Alice') }
  let(:sender_instance) do
    create(:character_instance,
           character: sender_character,
           current_room: room,
           reality: reality,
           online: true)
  end

  let(:recipient_character) { create(:character, forename: 'Bob') }
  let(:recipient_instance) do
    create(:character_instance,
           character: recipient_character,
           current_room: room,
           reality: reality,
           online: true)
  end

  let(:channel) { Channel.create(name: 'Test Channel', channel_type: 'ooc', is_public: true) }

  before do
    allow(BroadcastService).to receive(:to_character)
    # Make recipient_instance the primary instance
    allow(recipient_character).to receive(:primary_instance).and_return(recipient_instance)
    allow(sender_character).to receive(:primary_instance).and_return(sender_instance)
  end

  describe '.broadcast' do
    context 'with valid inputs' do
      before do
        ChannelMember.create(channel: channel, character: sender_character)
        ChannelMember.create(channel: channel, character: recipient_character)
      end

      it 'returns success' do
        result = described_class.broadcast(channel, sender_instance, 'Hello world!')
        expect(result[:success]).to be true
      end

      it 'returns member count' do
        result = described_class.broadcast(channel, sender_instance, 'Hello world!')
        expect(result[:member_count]).to be_a(Integer)
      end

      it 'returns channel name' do
        result = described_class.broadcast(channel, sender_instance, 'Hello world!')
        expect(result[:channel]).to eq('Test Channel')
      end

      it 'sends to BroadcastService' do
        described_class.broadcast(channel, sender_instance, 'Hello world!')
        expect(BroadcastService).to have_received(:to_character).at_least(:once)
      end
    end

    context 'with nil channel' do
      it 'returns error' do
        result = described_class.broadcast(nil, sender_instance, 'Hello')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/channel not found/i)
      end
    end

    context 'with nil sender' do
      it 'returns error' do
        result = described_class.broadcast(channel, nil, 'Hello')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/sender not found/i)
      end
    end

    context 'with muted members' do
      before do
        ChannelMember.create(channel: channel, character: sender_character)
        ChannelMember.create(channel: channel, character: recipient_character, is_muted: true)
      end

      it 'excludes muted members from broadcast' do
        result = described_class.broadcast(channel, sender_instance, 'Hello')
        # Should only send to sender (muted member excluded)
        # Member count should be 1 (sender only)
        expect(result[:member_count]).to eq(1)
      end
    end
  end

  describe '.online_members' do
    before do
      ChannelMember.create(channel: channel, character: sender_character)
      ChannelMember.create(channel: channel, character: recipient_character)
    end

    it 'returns online members' do
      members = described_class.online_members(channel)
      expect(members).to be_an(Array)
    end

    it 'excludes specified instances' do
      members = described_class.online_members(channel, exclude: [sender_instance])
      instance_ids = members.map(&:id)
      expect(instance_ids).not_to include(sender_instance.id)
    end

    context 'with muted member' do
      before do
        ChannelMember.where(channel: channel, character: recipient_character).update(is_muted: true)
      end

      it 'excludes muted members' do
        members = described_class.online_members(channel)
        member_character_ids = members.map { |m| m.character.id }
        expect(member_character_ids).not_to include(recipient_character.id)
      end
    end
  end

  describe '.find_channel' do
    it 'finds channel by name' do
      channel # create the channel
      result = described_class.find_channel('Test Channel')
      expect(result).to eq(channel)
    end

    it 'finds channel case-insensitively' do
      channel # create the channel
      result = described_class.find_channel('test channel')
      expect(result).to eq(channel)
    end

    it 'returns nil for non-existent channel' do
      result = described_class.find_channel('Non Existent')
      expect(result).to be_nil
    end

    context 'with universe scope' do
      let(:universe_channel) do
        Channel.create(name: 'Universe Channel', channel_type: 'ooc', is_public: true, universe_id: universe.id)
      end

      it 'scopes to universe when provided' do
        universe_channel # create it
        result = described_class.find_channel('Universe Channel', universe_id: universe.id)
        expect(result).to eq(universe_channel)
      end
    end
  end

  describe '.default_ooc_channel' do
    let!(:ooc_channel) { Channel.create(name: 'OOC', channel_type: 'ooc', is_public: true) }

    it 'returns OOC channel' do
      result = described_class.default_ooc_channel
      expect(result.channel_type).to eq('ooc')
    end

    context 'with universe-scoped OOC channel' do
      let!(:universe_ooc) do
        Channel.create(name: 'Universe OOC', channel_type: 'ooc', is_public: true, universe_id: universe.id)
      end

      it 'prefers universe-scoped channel' do
        result = described_class.default_ooc_channel(universe_id: universe.id)
        expect(result).to eq(universe_ooc)
      end

      it 'falls back to global OOC if no universe channel' do
        result = described_class.default_ooc_channel(universe_id: 999)
        expect(result.channel_type).to eq('ooc')
      end
    end
  end

  describe '.available_channels' do
    let!(:public_channel) { Channel.create(name: 'Public Chat', channel_type: 'ooc', is_public: true) }
    let!(:private_channel) { Channel.create(name: 'Private Chat', channel_type: 'ooc', is_public: false) }

    it 'returns public channels' do
      channels = described_class.available_channels(sender_character)
      channel_names = channels.map { |c| c[:name] }
      expect(channel_names).to include('Public Chat')
    end

    it 'excludes private channels user is not a member of' do
      channels = described_class.available_channels(sender_character)
      channel_names = channels.map { |c| c[:name] }
      expect(channel_names).not_to include('Private Chat')
    end

    context 'when user is member of private channel' do
      before do
        ChannelMember.create(channel: private_channel, character: sender_character)
      end

      it 'includes private channels user is a member of' do
        channels = described_class.available_channels(sender_character)
        channel_names = channels.map { |c| c[:name] }
        expect(channel_names).to include('Private Chat')
      end

      it 'includes membership info' do
        channels = described_class.available_channels(sender_character)
        private = channels.find { |c| c[:name] == 'Private Chat' }
        expect(private[:is_member]).to be true
      end
    end

    it 'returns channel info hashes' do
      channels = described_class.available_channels(sender_character)
      expect(channels).to all(include(:id, :name, :type, :is_member))
    end
  end
end
