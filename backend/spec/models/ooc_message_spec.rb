# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OocMessage, type: :model do
  let(:sender_user) { create(:user) }
  let(:recipient_user) { create(:user) }
  let(:sender_character) { create(:character, forename: 'Alice', user: sender_user) }

  describe 'validations' do
    it 'requires sender_user_id' do
      msg = OocMessage.new(
        recipient_user_id: recipient_user.id,
        content: 'Hello'
      )
      expect(msg.valid?).to be false
      expect(msg.errors[:sender_user_id]).not_to be_empty
    end

    it 'requires recipient_user_id' do
      msg = OocMessage.new(
        sender_user_id: sender_user.id,
        content: 'Hello'
      )
      expect(msg.valid?).to be false
      expect(msg.errors[:recipient_user_id]).not_to be_empty
    end

    it 'requires content' do
      msg = OocMessage.new(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id
      )
      expect(msg.valid?).to be false
      expect(msg.errors[:content]).not_to be_empty
    end

    it 'validates content minimum length' do
      msg = OocMessage.new(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: ''
      )
      expect(msg.valid?).to be false
    end

    it 'validates content maximum length' do
      msg = OocMessage.new(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'x' * 2001
      )
      expect(msg.valid?).to be false
    end

    it 'is valid with all required fields' do
      msg = OocMessage.new(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Hello!'
      )
      expect(msg.valid?).to be true
    end
  end

  describe '#mark_delivered!' do
    let(:msg) do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Test message'
      )
    end

    it 'marks message as delivered' do
      expect(msg.delivered?).to be false
      msg.mark_delivered!
      expect(msg.delivered?).to be true
    end

    it 'sets delivered_at timestamp' do
      expect(msg.delivered_at).to be_nil
      msg.mark_delivered!
      expect(msg.delivered_at).not_to be_nil
    end
  end

  describe '#format_for_recipient' do
    let(:msg) do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        sender_character_id: sender_character.id,
        content: 'Hello there!'
      )
    end

    it 'includes OOC prefix' do
      expect(msg.format_for_recipient).to include('[OOC from')
    end

    it 'includes sender name' do
      expect(msg.format_for_recipient).to include('Alice')
    end

    it 'includes message content' do
      expect(msg.format_for_recipient).to include('Hello there!')
    end
  end

  describe '#format_for_sender' do
    let(:recipient_char) { create(:character, forename: 'Bob', user: recipient_user) }
    let(:msg) do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        sender_character_id: sender_character.id,
        content: 'Hello there!'
      )
    end

    it 'includes OOC prefix' do
      expect(msg.format_for_sender(recipient_char: recipient_char)).to include('[OOC to')
    end

    it 'includes recipient name' do
      expect(msg.format_for_sender(recipient_char: recipient_char)).to include('Bob')
    end

    it 'includes message content' do
      expect(msg.format_for_sender).to include('Hello there!')
    end
  end

  describe '.pending_for' do
    let!(:delivered_msg) do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Delivered',
        delivered: true
      )
    end

    let!(:pending_msg) do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Pending',
        delivered: false
      )
    end

    it 'returns only undelivered messages' do
      pending = OocMessage.pending_for(recipient_user)
      expect(pending).to include(pending_msg)
      expect(pending).not_to include(delivered_msg)
    end

    it 'orders by created_at' do
      older_msg = OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Older',
        delivered: false,
        created_at: Time.now - 3600
      )

      pending = OocMessage.pending_for(recipient_user)
      expect(pending.first).to eq(older_msg)
    end
  end

  describe '.pending_count_for' do
    before do
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Pending 1',
        delivered: false
      )
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Pending 2',
        delivered: false
      )
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'Delivered',
        delivered: true
      )
    end

    it 'returns count of undelivered messages' do
      expect(OocMessage.pending_count_for(recipient_user)).to eq(2)
    end
  end

  describe '.recent_contacts_for' do
    let(:third_user) { create(:user) }

    before do
      # Messages to recipient_user
      OocMessage.create(
        sender_user_id: sender_user.id,
        recipient_user_id: recipient_user.id,
        content: 'To Bob'
      )

      # Messages from third_user
      OocMessage.create(
        sender_user_id: third_user.id,
        recipient_user_id: sender_user.id,
        content: 'From Charlie'
      )
    end

    it 'returns users sender has exchanged messages with' do
      contacts = OocMessage.recent_contacts_for(sender_user)
      expect(contacts.map(&:id)).to include(recipient_user.id)
      expect(contacts.map(&:id)).to include(third_user.id)
    end

    it 'limits results' do
      contacts = OocMessage.recent_contacts_for(sender_user, limit: 1)
      expect(contacts.length).to eq(1)
    end
  end
end
