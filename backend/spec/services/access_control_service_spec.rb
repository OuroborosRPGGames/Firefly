# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AccessControlService do
  let(:user) { create(:user, username: 'testuser', email: 'test@example.com') }
  let(:ip_address) { '192.168.1.100' }
  let(:connection_type) { 'web_login' }
  let(:user_agent) { 'Mozilla/5.0 Test Browser' }

  describe '.check_access' do
    context 'when IP is not banned and user is not suspended' do
      before do
        allow(IpBan).to receive(:find_matching_ban).and_return(nil)
      end

      it 'returns allowed true' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:allowed]).to be true
      end

      it 'does not include ban or reason' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to be_nil
        expect(result[:ban]).to be_nil
      end

      it 'logs successful connection' do
        expect(ConnectionLog).to receive(:log_connection).with(
          hash_including(
            ip_address: ip_address,
            connection_type: connection_type,
            outcome: 'success'
          )
        )
        described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
      end
    end

    context 'when IP is banned' do
      let(:ip_ban) do
        instance_double('IpBan',
                        reason: 'Spam',
                        expires_at: Time.now + 86400)
      end

      before do
        allow(IpBan).to receive(:find_matching_ban).and_return(ip_ban)
      end

      it 'returns allowed false' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:allowed]).to be false
      end

      it 'returns the ban object' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:ban]).to eq(ip_ban)
      end

      it 'returns formatted reason with expiry info' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('banned')
        expect(result[:reason]).to include('expires')
      end

      it 'logs blocked connection' do
        expect(ConnectionLog).to receive(:log_connection).with(
          hash_including(
            outcome: 'banned_ip'
          )
        )
        described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
      end
    end

    context 'when user is suspended' do
      before do
        allow(IpBan).to receive(:find_matching_ban).and_return(nil)
        allow(user).to receive(:suspended?).and_return(true)
        allow(user).to receive(:suspension_reason).and_return('Violation of rules')
        allow(user).to receive(:suspended_until).and_return(Time.now + 86400)
        allow(user).to receive(:suspension_remaining).and_return(86400)
      end

      it 'returns allowed false' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:allowed]).to be false
      end

      it 'returns formatted suspension message' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('suspended')
        expect(result[:reason]).to include('Violation of rules')
      end

      it 'logs blocked connection' do
        expect(ConnectionLog).to receive(:log_connection).with(
          hash_including(
            outcome: 'suspended'
          )
        )
        described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
      end
    end

    context 'with nil user' do
      before do
        allow(IpBan).to receive(:find_matching_ban).and_return(nil)
      end

      it 'returns allowed true if IP not banned' do
        result = described_class.check_access(
          user: nil,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:allowed]).to be true
      end
    end

    context 'with permanent suspension' do
      before do
        allow(IpBan).to receive(:find_matching_ban).and_return(nil)
        allow(user).to receive(:suspended?).and_return(true)
        allow(user).to receive(:suspension_reason).and_return('Permanent ban')
        allow(user).to receive(:suspended_until).and_return(nil)
      end

      it 'indicates permanent suspension' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('permanent')
      end
    end
  end

  describe '.ip_banned?' do
    it 'delegates to IpBan.banned?' do
      expect(IpBan).to receive(:banned?).with('10.0.0.1').and_return(true)
      expect(described_class.ip_banned?('10.0.0.1')).to be true
    end

    it 'returns false for non-banned IPs' do
      allow(IpBan).to receive(:banned?).and_return(false)
      expect(described_class.ip_banned?('10.0.0.2')).to be false
    end
  end

  describe '.log_failed_login' do
    it 'looks up user by username' do
      allow(User).to receive(:where).and_return(User.where(id: 0))
      allow(ConnectionLog).to receive(:log_connection)

      described_class.log_failed_login(
        username_or_email: 'testuser',
        ip_address: ip_address
      )

      expect(User).to have_received(:where)
    end

    it 'logs connection with invalid_credentials outcome' do
      allow(User).to receive(:where).and_return(User.where(id: 0))

      expect(ConnectionLog).to receive(:log_connection).with(
        hash_including(
          outcome: 'invalid_credentials',
          ip_address: ip_address
        )
      )

      described_class.log_failed_login(
        username_or_email: 'unknown',
        ip_address: ip_address
      )
    end

    it 'includes username in failure reason' do
      allow(User).to receive(:where).and_return(User.where(id: 0))

      expect(ConnectionLog).to receive(:log_connection).with(
        hash_including(
          failure_reason: include('unknown@example.com')
        )
      )

      described_class.log_failed_login(
        username_or_email: 'unknown@example.com',
        ip_address: ip_address
      )
    end
  end

  describe '.brute_force_detected?' do
    context 'when under threshold' do
      before do
        allow(ConnectionLog).to receive(:recent_failed_attempts).and_return(5)
      end

      it 'returns false' do
        expect(described_class.brute_force_detected?(ip_address)).to be false
      end
    end

    context 'when at threshold' do
      before do
        allow(ConnectionLog).to receive(:recent_failed_attempts).and_return(10)
      end

      it 'returns true' do
        expect(described_class.brute_force_detected?(ip_address)).to be true
      end
    end

    context 'when over threshold' do
      before do
        allow(ConnectionLog).to receive(:recent_failed_attempts).and_return(15)
      end

      it 'returns true' do
        expect(described_class.brute_force_detected?(ip_address)).to be true
      end
    end

    context 'with custom threshold' do
      before do
        allow(ConnectionLog).to receive(:recent_failed_attempts).and_return(3)
      end

      it 'uses custom threshold' do
        expect(described_class.brute_force_detected?(ip_address, threshold: 3)).to be true
        expect(described_class.brute_force_detected?(ip_address, threshold: 5)).to be false
      end
    end

    context 'with custom window' do
      it 'passes window to ConnectionLog' do
        expect(ConnectionLog).to receive(:recent_failed_attempts)
          .with(ip_address, minutes: 30)
          .and_return(0)

        described_class.brute_force_detected?(ip_address, window_minutes: 30)
      end
    end
  end

  describe 'ban message formatting' do
    let(:ip_ban) do
      instance_double('IpBan',
                      reason: nil,
                      expires_at: nil)
    end

    before do
      allow(IpBan).to receive(:find_matching_ban).and_return(ip_ban)
    end

    context 'with no reason' do
      it 'shows basic ban message' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to eq('This IP address has been banned.')
      end
    end

    context 'with empty reason' do
      let(:ip_ban) do
        instance_double('IpBan',
                        reason: '',
                        expires_at: nil)
      end

      it 'does not include reason' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).not_to include('Reason:')
      end
    end

    context 'with reason' do
      let(:ip_ban) do
        instance_double('IpBan',
                        reason: 'Spam activity',
                        expires_at: nil)
      end

      it 'includes reason in message' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('Reason: Spam activity')
      end
    end

    context 'with expiration in hours' do
      let(:ip_ban) do
        instance_double('IpBan',
                        reason: nil,
                        expires_at: Time.now + 7200) # 2 hours
      end

      it 'shows hours remaining' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('hour')
      end
    end

    context 'with expiration in minutes' do
      let(:ip_ban) do
        instance_double('IpBan',
                        reason: nil,
                        expires_at: Time.now + 600) # 10 minutes
      end

      it 'shows minutes remaining' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('minute')
      end
    end
  end

  describe 'suspension message formatting' do
    before do
      allow(IpBan).to receive(:find_matching_ban).and_return(nil)
      allow(user).to receive(:suspended?).and_return(true)
    end

    context 'with temporary suspension in hours' do
      before do
        allow(user).to receive(:suspension_reason).and_return(nil)
        allow(user).to receive(:suspended_until).and_return(Time.now + 7200)
        allow(user).to receive(:suspension_remaining).and_return(7200)
      end

      it 'shows hours remaining' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('hour')
      end
    end

    context 'with temporary suspension in minutes' do
      before do
        allow(user).to receive(:suspension_reason).and_return(nil)
        allow(user).to receive(:suspended_until).and_return(Time.now + 600)
        allow(user).to receive(:suspension_remaining).and_return(600)
      end

      it 'shows minutes remaining' do
        result = described_class.check_access(
          user: user,
          ip_address: ip_address,
          connection_type: connection_type
        )
        expect(result[:reason]).to include('minute')
      end
    end
  end
end
