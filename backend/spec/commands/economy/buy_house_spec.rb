# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::BuyHouse do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'buy house' : "buy house #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('buy house')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:economy)
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('buyhouse')
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    it 'returns web interface required result' do
      result = execute_command

      expect(result[:success]).to be true
      expect(result[:data][:requires_web]).to be true
      expect(result[:message]).to include('web interface')
    end

    it 'indicates buy_house action' do
      result = execute_command

      expect(result[:data][:action]).to eq('buy_house')
    end
  end
end
