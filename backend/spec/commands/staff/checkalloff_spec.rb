# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::CheckAllOff do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'checkalloff' : "checkalloff #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('checkalloff')
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

    context 'when no override is active' do
      before do
        allow(AbuseMonitoringService).to receive(:override_active?).and_return(false)
      end

      it 'returns error' do
        result = execute_command

        expect(result[:success]).to be false
        expect(result[:message]).to include('No abuse monitoring override')
      end
    end

    context 'when override is active' do
      let(:override) { double('Override', triggered_by_user: user, deactivate!: true) }

      before do
        allow(AbuseMonitoringService).to receive(:override_active?).and_return(true)
        allow(AbuseMonitoringOverride).to receive(:current).and_return(override)
        allow(StaffAlertService).to receive(:broadcast_to_staff)
      end

      it 'cancels the override' do
        result = execute_command

        expect(result[:success]).to be true
        expect(result[:message]).to include('cancelled')
      end
    end
  end
end
