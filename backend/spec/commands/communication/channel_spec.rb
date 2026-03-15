# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Channel, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  before do
    # Stub AbuseMonitoringService to allow messages by default
    allow(AbuseMonitoringService).to receive(:check_message).and_return({ allowed: true })
    # Stub BroadcastService to not actually send messages
    allow(BroadcastService).to receive(:to_character)
    # Stub user mute check
    allow(user).to receive(:muted?).and_return(false)
    allow(user).to receive(:check_mute_expired!)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with standard channel <name> <message> format' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC', is_public: true)
      end

      before do
        create(:channel_member, channel: ooc_channel, character: character)
      end

      it 'sends message to channel' do
        result = command.execute('channel ooc Hello everyone!')

        expect(result[:success]).to be true
        expect(result[:data][:channel_name]).to eq 'OOC'
        expect(result[:data][:message]).to eq 'Hello everyone!'
      end

      it 'returns error when no message provided' do
        result = command.execute('channel ooc')

        expect(result[:success]).to be false
        expect(result[:message]).to include('What do you want to say')
      end

      it 'returns error when channel not found' do
        result = command.execute('channel unknown Hello!')

        expect(result[:success]).to be false
        expect(result[:message]).to include("No channel found named")
        expect(result[:message]).to include("unknown")
      end

      it 'returns error when text is empty' do
        result = command.execute('channel')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with + shortcut' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC', is_public: true)
      end

      before do
        create(:channel_member, channel: ooc_channel, character: character)
      end

      it 'sends message to OOC channel' do
        result = command.execute('+ Quick message!')

        expect(result[:success]).to be true
        expect(result[:data][:channel_name]).to eq 'OOC'
        expect(result[:data][:message]).to eq 'Quick message!'
      end

      it 'returns error when no message provided' do
        result = command.execute('+')

        expect(result[:success]).to be false
        expect(result[:message]).to include('What do you want to say')
      end
    end

    context 'when not a member of private channel' do
      let!(:private_channel) do
        create(:channel, :private, universe: universe, name: 'Secret')
      end

      it 'returns error for private channels' do
        result = command.execute('channel secret Hello!')

        expect(result[:success]).to be false
        expect(result[:message]).to include("not a member")
      end
    end

    context 'when auto-joining public channels' do
      let!(:public_channel) do
        create(:channel, :ooc, universe: universe, name: 'Public', is_public: true)
      end

      it 'auto-joins and sends message' do
        # Character is NOT a member initially
        expect(ChannelMember.where(channel_id: public_channel.id, character_id: character.id).any?).to be false

        result = command.execute('channel public Hello!')

        expect(result[:success]).to be true
        # Should have been auto-joined
        expect(ChannelMember.where(channel_id: public_channel.id, character_id: character.id).any?).to be true
      end
    end

    context 'when muted in channel' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC', is_public: true)
      end

      before do
        create(:channel_member, channel: ooc_channel, character: character, is_muted: true)
      end

      it 'returns error' do
        result = command.execute('channel ooc Hello!')

        expect(result[:success]).to be false
        expect(result[:message]).to include('muted')
      end
    end

    context 'when no OOC channel exists' do
      before do
        # Clear all OOC channels
        Channel.where(channel_type: 'ooc').delete
      end

      it 'returns error for + shortcut' do
        result = command.execute('+ Hello!')

        expect(result[:success]).to be false
        expect(result[:message]).to include('No OOC channel exists')
      end
    end

    context 'resets messaging_mode to channel' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC', is_public: true)
      end

      before do
        create(:channel_member, channel: ooc_channel, character: character)
        # Set to ooc mode first
        character_instance.update(messaging_mode: 'ooc', ooc_target_names: 'SomeUser')
      end

      it 'resets messaging_mode when sending to channel' do
        command.execute('channel ooc Hello!')
        character_instance.reload

        expect(character_instance.messaging_mode).to eq('channel')
        expect(character_instance.last_channel_name).to eq('OOC')
      end
    end

    context 'with multi-word channel names' do
      let!(:long_name_channel) do
        create(:channel, :ic, universe: universe, name: 'North Market', is_public: true)
      end

      before do
        create(:channel_member, channel: long_name_channel, character: character)
      end

      it 'finds channel by prefix' do
        result = command.execute('channel north Hello market!')

        expect(result[:success]).to be true
        expect(result[:data][:channel_name]).to eq 'North Market'
        expect(result[:data][:message]).to eq 'Hello market!'
      end
    end
  end
end
