# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::NpcQuery do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'npcquery' : "npcquery #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('npcquery')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    context 'without arguments' do
      it 'returns usage error' do
        result = execute_command

        expect(result[:success]).to be false
      end
    end

    context 'with NPC name without question' do
      it 'returns error asking for question' do
        result = execute_command('Merchant')

        expect(result[:success]).to be false
        expect(result[:message]).to include('question')
      end
    end

    context 'with NPC name and question' do
      before do
        # No NPC found - stub only the NPC lookup query (online: true),
        # not all where() calls (which would break after_create hooks)
        npc_query_double = double(eager: double(all: []))
        allow(CharacterInstance).to receive(:where).and_call_original
        allow(CharacterInstance).to receive(:where)
          .with(online: true)
          .and_return(npc_query_double)
      end

      it 'returns error if NPC not found' do
        result = execute_command('Merchant What do you sell?')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not find')
      end

      it 'backward compat: works with = separator' do
        result = execute_command('Merchant = What do you sell?')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not find')
      end
    end
  end
end
