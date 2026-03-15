# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Channels, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when no channels exist' do
      before do
        # Clear any existing channels
        ChannelMember.dataset.delete
        Channel.dataset.delete
      end

      it 'returns helpful message' do
        result = command.execute('channels')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No channels available')
        expect(result[:data][:count]).to eq 0
      end
    end

    context 'when channels exist' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC', description: 'Out of character chat')
      end
      let!(:ic_channel) do
        create(:channel, :ic, universe: universe, name: 'World', description: 'In-character world chat')
      end

      before do
        # Join the OOC channel
        create(:channel_member, channel: ooc_channel, character: character)
      end

      it 'lists available channels' do
        result = command.execute('channels')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OOC')
        expect(result[:message]).to include('World')
        expect(result[:data][:count]).to eq 2
      end

      it 'shows joined status' do
        result = command.execute('channels')

        expect(result[:message]).to include('(joined)')
        expect(result[:message]).to include('(not joined)')
      end

      it 'shows channel descriptions' do
        result = command.execute('channels')

        expect(result[:message]).to include('Out of character chat')
        expect(result[:message]).to include('In-character world chat')
      end

      it 'includes usage instructions' do
        result = command.execute('channels')

        expect(result[:message]).to include("Use 'join channel")
        expect(result[:message]).to include("Use 'channel")
        expect(result[:message]).to include("Use 'ooc")
      end
    end

    context 'with aliases' do
      let!(:ooc_channel) do
        create(:channel, :ooc, universe: universe, name: 'OOC')
      end

      before do
        create(:channel_member, channel: ooc_channel, character: character)
      end

      it 'works with chanlist alias' do
        result = command.execute('chanlist')

        expect(result[:success]).to be true
        expect(result[:data][:count]).to eq 1
      end
    end
  end
end
