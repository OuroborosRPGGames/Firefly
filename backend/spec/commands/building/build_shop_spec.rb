# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::BuildShop do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'build shop' : "build shop #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('build shop')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:building)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without permission' do
      it 'returns permission denied' do
        result = execute_command('Test Shop')

        expect(result[:success]).to be false
      end
    end
  end
end
