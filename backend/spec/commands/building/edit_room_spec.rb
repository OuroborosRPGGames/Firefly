# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::EditRoom do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, is_admin: true) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'edit room' : "edit room #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('edit room')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:building)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    before do
      # Set actual ownership on the room
      room.update(owner_id: character.id)
    end

    it 'opens edit modal' do
      result = execute_command

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:form)
    end
  end
end
