# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DirectMessage do
  let(:sender) { create(:character) }
  let(:recipient) { create(:character) }

  describe 'associations' do
    it 'belongs to sender' do
      message = DirectMessage.new(sender_id: sender.id)
      expect(message.sender).to eq(sender)
    end

    it 'belongs to recipient' do
      message = DirectMessage.new(recipient_id: recipient.id)
      expect(message.recipient).to eq(recipient)
    end
  end

  describe 'validations' do
    it 'requires sender_id' do
      message = DirectMessage.new(recipient_id: recipient.id, content: 'Hello')
      expect(message.valid?).to be false
      expect(message.errors[:sender_id]).not_to be_empty
    end

    it 'requires recipient_id' do
      message = DirectMessage.new(sender_id: sender.id, content: 'Hello')
      expect(message.valid?).to be false
      expect(message.errors[:recipient_id]).not_to be_empty
    end

    it 'requires content' do
      message = DirectMessage.new(sender_id: sender.id, recipient_id: recipient.id)
      expect(message.valid?).to be false
      expect(message.errors[:content]).not_to be_empty
    end

    it 'requires content to be at least 1 character' do
      message = DirectMessage.new(sender_id: sender.id, recipient_id: recipient.id, content: '')
      expect(message.valid?).to be false
      expect(message.errors[:content]).not_to be_empty
    end

    it 'requires content to be at most 2000 characters' do
      message = DirectMessage.new(sender_id: sender.id, recipient_id: recipient.id, content: 'a' * 2001)
      expect(message.valid?).to be false
      expect(message.errors[:content]).not_to be_empty
    end

    it 'is valid with all required fields' do
      message = DirectMessage.new(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello')
      expect(message.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'strips whitespace from content' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: '  Hello World  ')
      expect(message.content).to eq('Hello World')
    end
  end

  describe '#mark_delivered!' do
    it 'sets delivered to true' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello')
      expect(message.delivered).to be false

      message.mark_delivered!
      message.refresh

      expect(message.delivered).to be true
    end

    it 'sets delivered_at timestamp' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello')
      expect(message.delivered_at).to be_nil

      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      message.mark_delivered!
      message.refresh

      expect(message.delivered_at).to be_within(1).of(freeze_time)
    end
  end

  describe '#delivered?' do
    it 'returns false when not delivered' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello')
      expect(message.delivered?).to be false
    end

    it 'returns true when delivered' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello', delivered: true)
      expect(message.delivered?).to be true
    end
  end

  describe '#format_for_recipient' do
    it 'formats message with sender name' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello there')
      expect(message.format_for_recipient).to eq("#{sender.full_name} messages: \"Hello there\"")
    end

    it 'handles missing sender' do
      message = DirectMessage.new(content: 'Hello')
      expect(message.format_for_recipient).to eq('Someone messages: "Hello"')
    end
  end

  describe '#format_for_sender' do
    it 'formats confirmation with recipient name' do
      message = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Hello there')
      expect(message.format_for_sender).to eq("You message #{recipient.full_name}: \"Hello there\"")
    end

    it 'handles missing recipient' do
      message = DirectMessage.new(content: 'Hello')
      expect(message.format_for_sender).to eq('You message someone: "Hello"')
    end
  end

  describe '.pending_for' do
    it 'returns undelivered messages for character' do
      pending_msg = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Pending', delivered: false)
      delivered_msg = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Delivered', delivered: true)

      result = DirectMessage.pending_for(recipient)

      expect(result).to include(pending_msg)
      expect(result).not_to include(delivered_msg)
    end

    it 'returns messages ordered by created_at' do
      older = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Older')
      # Small delay to ensure different timestamps
      newer = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Newer')

      result = DirectMessage.pending_for(recipient)

      expect(result.first).to eq(older)
      expect(result.last).to eq(newer)
    end

    it 'eager loads sender' do
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Test')
      result = DirectMessage.pending_for(recipient)

      # Check that sender is already loaded (no additional query)
      expect(result.first.associations).to have_key(:sender)
    end
  end

  describe '.pending_count_for' do
    it 'returns count of undelivered messages' do
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Pending 1', delivered: false)
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Pending 2', delivered: false)
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Delivered', delivered: true)

      expect(DirectMessage.pending_count_for(recipient)).to eq(2)
    end

    it 'returns 0 when no pending messages' do
      expect(DirectMessage.pending_count_for(recipient)).to eq(0)
    end
  end

  describe '.recent_sent_by' do
    let(:other_sender) { create(:character) }

    it 'returns messages sent by character' do
      my_msg = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'My message')
      other_msg = DirectMessage.create(sender_id: other_sender.id, recipient_id: recipient.id, content: 'Other message')

      result = DirectMessage.recent_sent_by(sender)

      expect(result).to include(my_msg)
      expect(result).not_to include(other_msg)
    end

    it 'orders by created_at descending' do
      older = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Older')
      newer = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Newer')

      result = DirectMessage.recent_sent_by(sender)

      expect(result.first).to eq(newer)
      expect(result.last).to eq(older)
    end

    it 'respects limit parameter' do
      5.times { |i| DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: "Message #{i}") }

      result = DirectMessage.recent_sent_by(sender, limit: 3)

      expect(result.length).to eq(3)
    end

    it 'defaults to limit of 20' do
      25.times { |i| DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: "Message #{i}") }

      result = DirectMessage.recent_sent_by(sender)

      expect(result.length).to eq(20)
    end

    it 'eager loads recipient' do
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Test')
      result = DirectMessage.recent_sent_by(sender)

      expect(result.first.associations).to have_key(:recipient)
    end
  end

  describe '.recent_received_by' do
    let(:other_recipient) { create(:character) }

    it 'returns messages received by character' do
      my_msg = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'To me')
      other_msg = DirectMessage.create(sender_id: sender.id, recipient_id: other_recipient.id, content: 'To other')

      result = DirectMessage.recent_received_by(recipient)

      expect(result).to include(my_msg)
      expect(result).not_to include(other_msg)
    end

    it 'orders by created_at descending' do
      older = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Older')
      newer = DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Newer')

      result = DirectMessage.recent_received_by(recipient)

      expect(result.first).to eq(newer)
      expect(result.last).to eq(older)
    end

    it 'respects limit parameter' do
      5.times { |i| DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: "Message #{i}") }

      result = DirectMessage.recent_received_by(recipient, limit: 3)

      expect(result.length).to eq(3)
    end

    it 'eager loads sender' do
      DirectMessage.create(sender_id: sender.id, recipient_id: recipient.id, content: 'Test')
      result = DirectMessage.recent_received_by(recipient)

      expect(result.first.associations).to have_key(:sender)
    end
  end
end
