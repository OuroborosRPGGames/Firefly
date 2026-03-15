# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Combat::Attack, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, status: 'alive')
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('attack')
    end

    it 'has global alias hit' do
      alias_names = described_class.alias_names
      expect(alias_names).to include('hit')
    end

    it 'has att alias' do
      alias_names = described_class.alias_names
      expect(alias_names).to include('att')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Attack')
    end
  end

  describe 'requirements' do
    it 'requires alive state' do
      requirements = described_class.requirements
      alive_req = requirements.find { |r| r[:type] == :character_state && r[:args]&.include?(:alive) }
      expect(alive_req).not_to be_nil
    end

    it 'requires standing position' do
      requirements = described_class.requirements
      standing_req = requirements.find { |r| r[:type] == :character_state && r[:args]&.include?(:standing) }
      expect(standing_req).not_to be_nil
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when target not in room' do
      it 'returns error about not seeing target' do
        result = command.execute('attack goblin')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see/i)
      end
    end

    context 'when no target specified' do
      it 'returns error asking who to attack' do
        result = command.execute('attack')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/who.*attack/i)
      end
    end

  end
end
