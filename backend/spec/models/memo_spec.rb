# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Memo do
  let(:sender) { create(:character, forename: 'Sender') }
  let(:recipient) { create(:character, forename: 'Recipient') }
  let(:memo) { create(:memo, sender: sender, recipient: recipient) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(memo).to be_valid
    end

    it 'requires sender_id' do
      memo = build(:memo, sender: nil, recipient: recipient)
      memo.sender_id = nil
      expect(memo).not_to be_valid
    end

    it 'requires recipient_id' do
      memo = build(:memo, sender: sender, recipient: nil)
      memo.recipient_id = nil
      expect(memo).not_to be_valid
    end

    it 'requires subject' do
      memo = build(:memo, sender: sender, recipient: recipient, subject: nil)
      expect(memo).not_to be_valid
    end

    it 'requires content' do
      memo = build(:memo, sender: sender, recipient: recipient, content: nil)
      expect(memo).not_to be_valid
    end

    it 'validates max length of subject' do
      memo = build(:memo, sender: sender, recipient: recipient, subject: 'x' * 201)
      expect(memo).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to sender' do
      expect(memo.sender).to eq(sender)
    end

    it 'belongs to recipient' do
      expect(memo.recipient).to eq(recipient)
    end
  end

  describe 'alias accessors' do
    it 'aliases body to content' do
      expect(memo.body).to eq(memo.content)
    end

    it 'aliases sent_at to created_at' do
      expect(memo.sent_at).to eq(memo.created_at)
    end
  end

  describe 'before_save callbacks' do
    it 'sets read to false if nil' do
      new_memo = Memo.create(sender_id: sender.id, recipient_id: recipient.id, subject: 'Test', content: 'Body')
      expect(new_memo.read).to eq(false)
    end
  end

  describe '#letter?' do
    it 'returns false (legacy behavior)' do
      expect(memo.letter?).to be false
    end
  end

  describe '#mark_read!' do
    it 'marks the memo as read' do
      memo.mark_read!
      expect(memo.reload.read).to be true
    end
  end

  describe '#unread?' do
    it 'returns true if not read' do
      memo.update(read: false)
      expect(memo.unread?).to be true
    end

    it 'returns false if read' do
      memo.update(read: true)
      expect(memo.unread?).to be false
    end
  end

  describe '#reply_to!' do
    it 'creates a reply memo' do
      reply = memo.reply_to!('This is my reply.')
      expect(reply).to be_a(Memo)
      expect(reply.sender_id).to eq(recipient.id)
      expect(reply.recipient_id).to eq(sender.id)
      expect(reply.subject).to start_with('Re: ')
      expect(reply.content).to eq('This is my reply.')
    end
  end

  describe '.unread_for' do
    let!(:unread_memo) { create(:memo, :unread, recipient: recipient) }
    let!(:read_memo) { create(:memo, :read, recipient: recipient) }
    let!(:other_memo) { create(:memo, :unread) }

    it 'returns unread memos for the character' do
      results = described_class.unread_for(recipient)
      expect(results).to include(unread_memo)
      expect(results).not_to include(read_memo)
      expect(results).not_to include(other_memo)
    end
  end

  describe '.inbox_for' do
    let!(:my_memo1) { create(:memo, recipient: recipient) }
    let!(:my_memo2) { create(:memo, recipient: recipient) }
    let!(:other_memo) { create(:memo) }

    it 'returns all memos for the character' do
      results = described_class.inbox_for(recipient)
      expect(results).to include(my_memo1, my_memo2)
      expect(results).not_to include(other_memo)
    end
  end

  describe '.sent_by' do
    let!(:sent_memo1) { create(:memo, sender: sender) }
    let!(:sent_memo2) { create(:memo, sender: sender) }
    let!(:other_memo) { create(:memo) }

    it 'returns all memos sent by the character' do
      results = described_class.sent_by(sender)
      expect(results).to include(sent_memo1, sent_memo2)
      expect(results).not_to include(other_memo)
    end
  end
end
