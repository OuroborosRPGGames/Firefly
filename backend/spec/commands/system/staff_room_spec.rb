# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::StaffRoom do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'staff room' : "staff room #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('staffroom')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:system)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    let!(:staff_room) { create(:room, name: 'Staff Room', room_type: 'staff') }

    it 'teleports to staff room' do
      result = execute_command

      expect(result[:success]).to be true
    end
  end
end
