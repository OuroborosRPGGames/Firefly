# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::SceneInstructions do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'sceneinstructions' : "sceneinstructions #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('sceneinstructions')
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
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with only scene id (no instructions)' do
      it 'returns error about missing instructions' do
        result = execute_command('5')

        expect(result[:success]).to be false
        expect(result[:message]).to include('instructions')
      end
    end

    context 'with scene id and instructions' do
      before do
        allow(ArrangedScene).to receive(:[]).and_return(nil)
      end

      it 'returns error if scene not found' do
        result = execute_command('1 Test instructions')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not find scene')
      end

      it 'backward compat: works with = separator' do
        result = execute_command('1 = Test instructions')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Could not find scene')
      end
    end
  end
end
