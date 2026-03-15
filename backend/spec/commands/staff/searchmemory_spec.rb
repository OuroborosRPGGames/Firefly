# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::SearchMemory do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'searchmemory' : "searchmemory #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('searchmemory')
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

    context 'with search term' do
      before do
        allow(LLM::Client).to receive(:embed).and_return({ success: false })
      end

      it 'searches world memories' do
        result = execute_command('dragon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No matching memories')
      end
    end
  end
end
