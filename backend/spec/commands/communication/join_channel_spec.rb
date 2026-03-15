# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::JoinChannel do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  let(:channel) { double('Channel', id: 1, name: 'OOC', is_public: true, member?: false, add_member: true) }

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'join channel' : "join channel #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('join channel')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:communication)
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('joinchannel')
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without channel name' do
      it 'returns usage error' do
        result = execute_command

        expect(result[:success]).to be false
        expect(result[:message]).to include('Which channel')
      end
    end

    context 'with unknown channel' do
      before do
        allow(ChannelBroadcastService).to receive(:find_channel).and_return(nil)
      end

      it 'returns not found error' do
        result = execute_command('Unknown')

        expect(result[:success]).to be false
        expect(result[:message]).to include('No channel found')
      end
    end

    context 'when already a member' do
      before do
        allow(ChannelBroadcastService).to receive(:find_channel).and_return(channel)
        allow(channel).to receive(:member?).and_return(true)
      end

      it 'returns already member error' do
        result = execute_command('OOC')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already a member')
      end
    end

    context 'with valid public channel' do
      before do
        allow(ChannelBroadcastService).to receive(:find_channel).and_return(channel)
        allow(ChannelBroadcastService).to receive(:online_members).and_return([])
      end

      it 'joins the channel' do
        result = execute_command('OOC')

        expect(result[:success]).to be true
        expect(result[:message]).to include('joined')
        expect(channel).to have_received(:add_member)
      end
    end
  end
end
