# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::DeleteLocation do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, is_admin: true) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'delete location' : "delete location #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('delete location')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:navigation)
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
      end
    end
  end
end
