# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Summon do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'summon' : "summon #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('summon')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('call')
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without arguments' do
      it 'returns usage error' do
        result = execute_command

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with only NPC name (no message)' do
      it 'returns error requesting message' do
        result = execute_command('Guard')

        expect(result[:success]).to be false
        expect(result[:message]).to include('message')
      end
    end

    context 'with npc and message' do
      before do
        allow(NpcLeadershipService).to receive(:find_npc_in_summon_range).and_return(nil)
      end

      it 'returns error if NPC not found' do
        result = execute_command('Unknown Hello')

        expect(result[:success]).to be false
        # Message contains HTML entities (&#39; for apostrophe)
        expect(result[:message]).to match(/know how to reach anyone named/)
      end

      it 'backward compat: works with = separator' do
        result = execute_command('Unknown = Hello')

        expect(result[:success]).to be false
        expect(result[:message]).to match(/know how to reach anyone named/)
      end
    end
  end
end
