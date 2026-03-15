# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OocRequest do
  let(:sender_user) { create(:user) }
  let(:target_user) { create(:user) }
  let(:sender_character) { create(:character, user: sender_user) }

  # Helper to create a valid request
  def create_request(attrs = {})
    req = OocRequest.new
    req.sender_user = attrs[:sender_user] || sender_user
    req.target_user = attrs[:target_user] || target_user
    req.sender_character = attrs[:sender_character] if attrs[:sender_character]
    req.message = attrs[:message] || 'I would like to discuss the plot.'
    req.status = attrs[:status] || 'pending'
    req.cooldown_until = attrs[:cooldown_until] if attrs[:cooldown_until]
    req.responded_at = attrs[:responded_at] if attrs[:responded_at]
    req.save
    req
  end

  describe 'associations' do
    it 'belongs to sender_user' do
      request = create_request(sender_user: sender_user)
      expect(request.sender_user.id).to eq(sender_user.id)
    end

    it 'belongs to target_user' do
      request = create_request(target_user: target_user)
      expect(request.target_user.id).to eq(target_user.id)
    end

    it 'belongs to sender_character' do
      request = create_request(sender_character: sender_character)
      expect(request.sender_character.id).to eq(sender_character.id)
    end
  end

  describe 'validations' do
    it 'requires sender_user_id' do
      req = OocRequest.new(target_user_id: target_user.id, message: 'Test')
      expect(req.valid?).to be false
      expect(req.errors[:sender_user_id]).not_to be_empty
    end

    it 'requires target_user_id' do
      req = OocRequest.new(sender_user_id: sender_user.id, message: 'Test')
      expect(req.valid?).to be false
      expect(req.errors[:target_user_id]).not_to be_empty
    end

    it 'requires message' do
      req = OocRequest.new(sender_user_id: sender_user.id, target_user_id: target_user.id)
      expect(req.valid?).to be false
      expect(req.errors[:message]).not_to be_empty
    end

    %w[pending accepted declined].each do |status|
      it "accepts #{status} as status" do
        req = OocRequest.new(
          sender_user_id: sender_user.id,
          target_user_id: target_user.id,
          message: 'Test',
          status: status
        )
        expect(req.valid?).to be true
      end
    end

    it 'rejects invalid status' do
      req = OocRequest.new(
        sender_user_id: sender_user.id,
        target_user_id: target_user.id,
        message: 'Test',
        status: 'invalid'
      )
      expect(req.valid?).to be false
    end

    it 'validates message length' do
      req = OocRequest.new(
        sender_user_id: sender_user.id,
        target_user_id: target_user.id,
        message: 'a' * 501
      )
      expect(req.valid?).to be false
      expect(req.errors[:message]).not_to be_empty
    end
  end

  describe '#pending?' do
    it 'returns true when status is pending' do
      request = create_request(status: 'pending')
      expect(request.pending?).to be true
    end

    it 'returns false for other statuses' do
      request = create_request(status: 'accepted')
      expect(request.pending?).to be false
    end
  end

  describe '#accepted?' do
    it 'returns true when status is accepted' do
      request = create_request(status: 'accepted')
      expect(request.accepted?).to be true
    end

    it 'returns false for other statuses' do
      request = create_request(status: 'pending')
      expect(request.accepted?).to be false
    end
  end

  describe '#declined?' do
    it 'returns true when status is declined' do
      request = create_request(status: 'declined')
      expect(request.declined?).to be true
    end

    it 'returns false for other statuses' do
      request = create_request(status: 'pending')
      expect(request.declined?).to be false
    end
  end

  describe '#accept!' do
    it 'sets status to accepted' do
      request = create_request(status: 'pending')
      request.accept!
      request.refresh

      expect(request.status).to eq('accepted')
    end

    it 'sets responded_at' do
      request = create_request(status: 'pending')
      request.accept!
      request.refresh

      expect(request.responded_at).not_to be_nil
    end
  end

  describe '#decline!' do
    it 'sets status to declined' do
      request = create_request(status: 'pending')
      request.decline!
      request.refresh

      expect(request.status).to eq('declined')
    end

    it 'sets responded_at' do
      request = create_request(status: 'pending')
      request.decline!
      request.refresh

      expect(request.responded_at).not_to be_nil
    end

    it 'sets cooldown_until' do
      request = create_request(status: 'pending')
      request.decline!
      request.refresh

      expect(request.cooldown_until).to be > Time.now
    end
  end

  describe '.in_cooldown?' do
    it 'returns true when sender has declined request with active cooldown' do
      create_request(
        sender_user: sender_user,
        target_user: target_user,
        status: 'declined',
        cooldown_until: Time.now + 3600
      )

      expect(OocRequest.in_cooldown?(sender_user, target_user)).to be true
    end

    it 'returns false when no declined requests' do
      expect(OocRequest.in_cooldown?(sender_user, target_user)).to be false
    end

    it 'returns false when cooldown has expired' do
      create_request(
        sender_user: sender_user,
        target_user: target_user,
        status: 'declined',
        cooldown_until: Time.now - 60
      )

      expect(OocRequest.in_cooldown?(sender_user, target_user)).to be false
    end
  end

  describe '.pending_for' do
    it 'returns pending requests for user' do
      request = create_request(target_user: target_user, status: 'pending')

      results = OocRequest.pending_for(target_user).all

      expect(results.map(&:id)).to include(request.id)
    end

    it 'does not include non-pending requests' do
      create_request(target_user: target_user, status: 'accepted')

      results = OocRequest.pending_for(target_user).all

      expect(results).to be_empty
    end
  end

  describe '.has_accepted_request?' do
    it 'returns true when accepted request exists' do
      create_request(
        sender_user: sender_user,
        target_user: target_user,
        status: 'accepted'
      )

      expect(OocRequest.has_accepted_request?(sender_user, target_user)).to be true
    end

    it 'returns false when no accepted request' do
      create_request(
        sender_user: sender_user,
        target_user: target_user,
        status: 'pending'
      )

      expect(OocRequest.has_accepted_request?(sender_user, target_user)).to be false
    end
  end

  describe '#cooldown_remaining' do
    it 'returns nil when no cooldown' do
      request = create_request(status: 'pending')
      expect(request.cooldown_remaining).to be_nil
    end

    it 'returns remaining seconds when in cooldown' do
      request = create_request(
        status: 'declined',
        cooldown_until: Time.now + 1800
      )

      expect(request.cooldown_remaining).to be_within(5).of(1800)
    end

    it 'returns nil when cooldown has expired' do
      request = create_request(
        status: 'declined',
        cooldown_until: Time.now - 60
      )

      expect(request.cooldown_remaining).to be_nil
    end
  end
end
