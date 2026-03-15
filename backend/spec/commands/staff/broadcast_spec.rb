# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::Broadcast do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'broadcast' : "broadcast #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('broadcast')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without message' do
      it 'returns usage error' do
        result = execute_command

        expect(result[:success]).to be false
      end
    end

    context 'with message' do
      let(:broadcast) { double('StaffBroadcast', deliver!: 5) }

      before do
        allow(user).to receive(:staff?).and_return(true)
        allow(StaffBroadcast).to receive(:create).and_return(broadcast)
      end

      it 'broadcasts message globally' do
        result = execute_command('Server restart in 5 minutes')

        expect(result[:success]).to be true
        expect(StaffBroadcast).to have_received(:create)
      end
    end
  end
end
