# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmailService do
  describe 'class methods' do
    it 'responds to configured?' do
      expect(described_class).to respond_to(:configured?)
    end

    it 'responds to send_verification_email' do
      expect(described_class).to respond_to(:send_verification_email)
    end

    it 'responds to send_password_reset' do
      expect(described_class).to respond_to(:send_password_reset)
    end

    it 'responds to send_email' do
      expect(described_class).to respond_to(:send_email)
    end

    it 'responds to send_test_email' do
      expect(described_class).to respond_to(:send_test_email)
    end
  end

  describe '.configured?' do
    it 'returns false when API key is not set' do
      allow(GameSetting).to receive(:get).with('sendgrid_api_key').and_return(nil)
      allow(GameSetting).to receive(:get).with('email_from_address').and_return('test@example.com')
      expect(described_class.configured?).to be false
    end

    it 'returns false when from address is not set' do
      allow(GameSetting).to receive(:get).with('sendgrid_api_key').and_return('sg_key_123')
      allow(GameSetting).to receive(:get).with('email_from_address').and_return(nil)
      expect(described_class.configured?).to be false
    end

    it 'returns true when both API key and from address are set' do
      allow(GameSetting).to receive(:get).with('sendgrid_api_key').and_return('sg_key_123')
      allow(GameSetting).to receive(:get).with('email_from_address').and_return('test@example.com')
      expect(described_class.configured?).to be true
    end
  end

  describe '.send_password_reset' do
    let(:user) { create(:user, email: 'reset@example.com') }

    it 'returns false when not configured' do
      allow(described_class).to receive(:configured?).and_return(false)
      expect(described_class.send_password_reset(user)).to be false
    end

    context 'when configured' do
      before do
        allow(described_class).to receive(:configured?).and_return(true)
        allow(described_class).to receive(:send_email).and_return(true)
      end

      it 'generates a password reset token for the user' do
        expect(user).to receive(:generate_password_reset_token!).and_return('test-token')
        described_class.send_password_reset(user)
      end

      it 'calls send_email with correct parameters' do
        expect(described_class).to receive(:send_email).with(
          to: user.email,
          subject: anything,
          body: anything,
          html: true
        ).and_return(true)
        described_class.send_password_reset(user)
      end
    end
  end

  describe '.send_verification_email' do
    let(:user) { create(:user, email: 'verify@example.com') }

    it 'returns false when not configured' do
      allow(described_class).to receive(:configured?).and_return(false)
      expect(described_class.send_verification_email(user)).to be false
    end

    context 'when configured' do
      before do
        allow(described_class).to receive(:configured?).and_return(true)
        allow(described_class).to receive(:send_email).and_return(true)
      end

      it 'generates a confirmation token for the user' do
        expect(user).to receive(:generate_confirmation_token!).and_return('test-token')
        described_class.send_verification_email(user)
      end

      it 'calls send_email with correct parameters' do
        expect(described_class).to receive(:send_email).with(
          to: user.email,
          subject: anything,
          body: anything,
          html: true
        ).and_return(true)
        described_class.send_verification_email(user)
      end
    end
  end
end
