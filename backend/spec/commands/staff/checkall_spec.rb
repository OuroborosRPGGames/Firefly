# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::CheckAll, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Staff') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(StaffAlertService).to receive(:broadcast_to_staff)
    allow(AbuseMonitoringService).to receive(:override_active?).and_return(false)
    allow(AbuseMonitoringService).to receive(:activate_override!).and_return(
      double('AbuseMonitoringOverride', active_until: Time.now + 3600)
    )
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'checkall', :staff, ['abusecheck', 'moderateall', 'abusescan']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['checkall']).to eq(described_class)
    end
  end

  describe 'permission validation' do
    context 'when character is not staff' do
      before do
        allow(character).to receive(:staff?).and_return(false)
      end

      it 'rejects non-staff users' do
        result = command.execute('checkall')

        expect(result[:success]).to be false
        expect(result[:message]).to include('staff members')
      end
    end

    context 'when character is staff' do
      before do
        allow(character).to receive(:staff?).and_return(true)
      end

      it 'allows staff members' do
        result = command.execute('checkall')

        expect(result[:success]).to be true
      end
    end
  end

  describe 'override activation' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'activates abuse monitoring override' do
      command.execute('checkall')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
    end

    it 'passes staff user to service' do
      command.execute('checkall')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(staff_user: user))
    end

    it 'uses default 1 hour duration' do
      command.execute('checkall')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(duration_hours: 1))
    end

    it 'sets custom duration if provided' do
      command.execute('checkall 4')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(duration_hours: 4))
    end

    it 'caps duration at 24 hours' do
      command.execute('checkall 48')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(duration_hours: 24))
    end

    it 'uses minimum 1 hour duration' do
      command.execute('checkall 0')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(duration_hours: 1))
    end

    it 'sets reason if provided' do
      command.execute('checkall 2 Suspected coordinated abuse')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(reason: 'Suspected coordinated abuse'))
    end

    it 'uses default reason when not provided' do
      command.execute('checkall')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(reason: a_string_including('checkall command')))
    end

    it 'handles reason without duration' do
      command.execute('checkall Suspicious activity')

      expect(AbuseMonitoringService).to have_received(:activate_override!)
        .with(hash_including(
          duration_hours: 1,
          reason: 'Suspicious activity'
        ))
    end
  end

  describe 'staff notification' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'notifies staff channel' do
      command.execute('checkall')

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(a_string_including('activated abuse monitoring override'), hash_including(category: :moderation))
    end

    it 'includes character name in notification' do
      command.execute('checkall')

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(a_string_including(character.full_name), anything)
    end

    it 'includes duration in notification' do
      command.execute('checkall 3')

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(a_string_including('3 hour'), anything)
    end

    it 'includes reason in notification' do
      command.execute('checkall 2 Testing the system')

      expect(StaffAlertService).to have_received(:broadcast_to_staff)
        .with(a_string_including('Testing the system'), anything)
    end
  end

  describe 'when override already active' do
    before do
      allow(character).to receive(:staff?).and_return(true)
      allow(AbuseMonitoringService).to receive(:override_active?).and_return(true)
      allow(AbuseMonitoringOverride).to receive(:current).and_return(
        double(
          'AbuseMonitoringOverride',
          triggered_by_user: double('User', username: 'OtherStaff'),
          active_until: Time.now + 1800
        )
      )
    end

    it 'returns error if already active' do
      result = command.execute('checkall')

      expect(result[:success]).to be false
      expect(result[:message]).to include('already active')
    end

    it 'shows who activated it' do
      result = command.execute('checkall')

      expect(result[:message]).to include('OtherStaff')
    end

    it 'shows when it expires' do
      result = command.execute('checkall')

      expect(result[:message]).to include('Expires')
    end

    it 'does not call activate_override!' do
      command.execute('checkall')

      expect(AbuseMonitoringService).not_to have_received(:activate_override!)
    end
  end

  describe 'response format' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'returns success with confirmation message' do
      result = command.execute('checkall')

      expect(result[:success]).to be true
      expect(result[:message]).to include('activated')
    end

    it 'mentions monitoring all players' do
      result = command.execute('checkall')

      expect(result[:message]).to include('All players will be monitored')
    end

    it 'mentions how to cancel' do
      result = command.execute('checkall')

      expect(result[:message]).to include('checkalloff')
    end

    it 'includes structured data' do
      result = command.execute('checkall 2 Test reason')

      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('abuse_override_activated')
      expect(result[:data][:duration_hours]).to eq(2)
      expect(result[:data][:reason]).to eq('Test reason')
      expect(result[:data][:expires_at]).not_to be_nil
    end
  end
end
