# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OocMessageService do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:user3) { create(:user) }
  let(:character1) { create(:character, forename: 'Alice', user: user1) }
  let(:character2) { create(:character, forename: 'Bob', user: user2) }
  let(:character3) { create(:character, forename: 'Charlie', user: user3) }
  let(:instance1) { create(:character_instance, character: character1, current_room: room, reality: reality, online: true) }
  let(:instance2) { create(:character_instance, character: character2, current_room: room, reality: reality, online: true) }
  let(:instance3) { create(:character_instance, character: character3, current_room: room, reality: reality, online: true) }

  describe '.send_message' do
    context 'with valid recipients' do
      before { instance2 }

      it 'sends message to single recipient' do
        result = described_class.send_message(instance1, [user2], 'Hello Bob!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OOC to Bob')
      end

      it 'creates OocMessage record' do
        expect {
          described_class.send_message(instance1, [user2], 'Hello!')
        }.to change { OocMessage.count }.by(1)

        msg = OocMessage.last
        expect(msg.sender_user_id).to eq(user1.id)
        expect(msg.recipient_user_id).to eq(user2.id)
        expect(msg.content).to eq('Hello!')
      end

      it 'marks message as delivered when recipient is online' do
        described_class.send_message(instance1, [user2], 'Test')

        msg = OocMessage.last
        expect(msg.delivered?).to be true
      end

      it 'sanitizes unsafe HTML while preserving color formatting' do
        result = described_class.send_message(
          instance1,
          [user2],
          '<span style="color: #00ff00; font-size: 24px" onclick="alert(1)">Hello</span><script>alert(1)</script>'
        )

        expect(result[:success]).to be true
        expect(result[:data][:content]).to include('style="color: #00ff00"')
        expect(result[:data][:content]).not_to include('font-size')
        expect(result[:data][:content]).not_to include('onclick')
        expect(result[:data][:content]).not_to include('<script')

        msg = OocMessage.last
        expect(msg.content).to eq(result[:data][:content])
      end
    end

    context 'with multiple recipients' do
      before do
        instance2
        instance3
      end

      it 'sends to multiple recipients' do
        result = described_class.send_message(instance1, [user2, user3], 'Hello all!')

        expect(result[:success]).to be true
        expect(result[:data][:sent_count]).to eq(2)
      end

      it 'creates multiple OocMessage records' do
        expect {
          described_class.send_message(instance1, [user2, user3], 'Hello!')
        }.to change { OocMessage.count }.by(2)
      end
    end

    context 'when recipient is offline' do
      before { instance2.update(online: false) }

      it 'stores message for later' do
        result = described_class.send_message(instance1, [user2], 'Offline test')

        expect(result[:success]).to be true
        msg = OocMessage.last
        expect(msg.delivered?).to be false
      end
    end

    context 'with no recipients' do
      it 'returns error' do
        result = described_class.send_message(instance1, [], 'Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no recipients/i)
      end
    end

    context 'with nil recipients' do
      it 'returns error' do
        result = described_class.send_message(instance1, nil, 'Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no recipients/i)
      end
    end

    context 'with empty message' do
      before { instance2 }

      it 'returns error' do
        result = described_class.send_message(instance1, [user2], '')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to say/i)
      end

      it 'returns error when message becomes empty after sanitization' do
        result = described_class.send_message(instance1, [user2], '<script>alert(1)</script>')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to say/i)
      end
    end

    context 'when sender tries to message themselves' do
      it 'returns error' do
        result = described_class.send_message(instance1, [user1], 'Hello me!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/yourself/i)
      end
    end

    context 'when recipient has OOC blocked' do
      before do
        instance2
        UserPermission.generic_for(user2).update(ooc_messaging: 'no')
      end

      it 'returns blocked error' do
        result = described_class.send_message(instance1, [user2], 'Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/blocked/i)
      end
    end

    context 'when recipient requires OOC request' do
      before do
        instance2
        UserPermission.generic_for(user2).update(ooc_messaging: 'ask')
      end

      it 'returns request required error' do
        result = described_class.send_message(instance1, [user2], 'Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/oocrequest|request first/i)
      end

      context 'when OOC request has been accepted' do
        before do
          OocRequest.create(
            sender_user_id: user1.id,
            target_user_id: user2.id,
            sender_character_id: character1.id,
            message: 'Can we chat?',
            status: 'accepted'
          )
        end

        it 'allows message' do
          result = described_class.send_message(instance1, [user2], 'Hello!')

          expect(result[:success]).to be true
        end
      end
    end

    context 'with mixed permission statuses' do
      before do
        instance2
        instance3
        # Bob allows, Charlie blocks
        UserPermission.generic_for(user3).update(ooc_messaging: 'no')
      end

      it 'sends to allowed recipients only' do
        result = described_class.send_message(instance1, [user2, user3], 'Hello!')

        expect(result[:success]).to be true
        expect(result[:data][:sent_count]).to eq(1)
        expect(result[:data][:blocked_names]).to include('Charlie')
      end

      it 'includes warning about blocked recipients' do
        result = described_class.send_message(instance1, [user2, user3], 'Hello!')

        expect(result[:message]).to match(/charlie blocked/i)
      end
    end
  end

  describe '.deliver_pending' do
    before do
      # Create online instance FIRST so auto-delivery runs on empty inbox
      instance2

      # Then create pending messages for user2
      OocMessage.create(
        sender_user_id: user1.id,
        recipient_user_id: user2.id,
        sender_character_id: character1.id,
        content: 'Pending 1',
        delivered: false
      )
      OocMessage.create(
        sender_user_id: user1.id,
        recipient_user_id: user2.id,
        sender_character_id: character1.id,
        content: 'Pending 2',
        delivered: false
      )
    end

    it 'delivers pending messages' do
      count = described_class.deliver_pending(user2)

      expect(count).to eq(2)
      expect(OocMessage.pending_count_for(user2)).to eq(0)
    end

    it 'marks messages as delivered' do
      described_class.deliver_pending(user2)

      OocMessage.where(recipient_user_id: user2.id).each do |msg|
        expect(msg.delivered?).to be true
      end
    end

    it 'returns 0 when no pending messages' do
      count = described_class.deliver_pending(user1)

      expect(count).to eq(0)
    end

    it 'returns 0 when user has no online instance' do
      instance2.update(online: false)

      count = described_class.deliver_pending(user2)

      expect(count).to eq(0)
    end
  end

  describe '.pending_count' do
    before do
      OocMessage.create(
        sender_user_id: user1.id,
        recipient_user_id: user2.id,
        content: 'Pending',
        delivered: false
      )
      OocMessage.create(
        sender_user_id: user1.id,
        recipient_user_id: user2.id,
        content: 'Delivered',
        delivered: true
      )
    end

    it 'returns count of pending messages' do
      expect(described_class.pending_count(user2)).to eq(1)
    end
  end
end
