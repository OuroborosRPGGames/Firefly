# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DirectMessageService do
  let(:room) { create(:room) }
  let(:other_room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:sender_character) { create(:character, forename: 'Alice') }
  let(:sender_instance) { create(:character_instance, character: sender_character, current_room: room, reality: reality, online: true) }
  let(:recipient_character) { create(:character, forename: 'Bob') }
  let(:recipient_instance) { create(:character_instance, character: recipient_character, current_room: other_room, reality: reality, online: true) }

  before do
    GameSetting.set('time_period', 'modern', type: 'string')
    # Modern era requires a phone for DMs
    create(:item, name: 'mobile phone', is_phone: true, character_instance: sender_instance)
  end

  describe '.send_message' do
    context 'with valid inputs in modern era' do
      before { recipient_instance }

      it 'creates a DirectMessage record' do
        expect {
          described_class.send_message(sender_instance, recipient_character, 'Hello!')
        }.to change { DirectMessage.count }.by(1)
      end

      it 'returns success result' do
        result = described_class.send_message(sender_instance, recipient_character, 'Hello!')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Bob')
      end

      it 'marks message as delivered when recipient is online' do
        described_class.send_message(sender_instance, recipient_character, 'Hello!')

        dm = DirectMessage.last
        expect(dm.delivered?).to be true
        expect(dm.delivered_at).not_to be_nil
      end

      it 'includes message data in result' do
        result = described_class.send_message(sender_instance, recipient_character, 'Hello!')

        expect(result[:data][:recipient_name]).to eq('Bob')
        expect(result[:data][:content]).to eq('Hello!')
      end

      it 'sanitizes unsafe HTML while preserving color formatting' do
        result = described_class.send_message(
          sender_instance,
          recipient_character,
          '<span style="color: #ff0000; font-size: 20px" onclick="alert(1)">Hi</span><script>alert(1)</script>'
        )

        expect(result[:success]).to be true
        expect(result[:data][:content]).to include('style="color: #ff0000"')
        expect(result[:data][:content]).not_to include('font-size')
        expect(result[:data][:content]).not_to include('onclick')
        expect(result[:data][:content]).not_to include('<script')

        dm = DirectMessage.last
        expect(dm.content).to eq(result[:data][:content])
      end
    end

    context 'when recipient is offline' do
      before do
        recipient_instance.update(online: false)
      end

      it 'stores message for later delivery' do
        result = described_class.send_message(sender_instance, recipient_character, 'Offline message')

        expect(result[:success]).to be true
        expect(result[:message]).to include('offline')

        dm = DirectMessage.last
        expect(dm.delivered?).to be false
      end
    end

    context 'with invalid inputs' do
      it 'returns error for nil recipient' do
        result = described_class.send_message(sender_instance, nil, 'Hello!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/could not find/i)
      end

      it 'returns error for empty message' do
        result = described_class.send_message(sender_instance, recipient_character, '')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to say/i)
      end

      it 'returns error when message becomes empty after sanitization' do
        result = described_class.send_message(sender_instance, recipient_character, '<script>alert(1)</script>')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/what do you want to say/i)
      end

      it 'returns error for messaging self' do
        result = described_class.send_message(sender_instance, sender_character, 'Hello me!')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/yourself/i)
      end
    end

    # Note: MessengerService (medieval/gaslight era delayed messaging) was removed
    # All eras now use direct DM delivery
  end

  describe '.deliver_pending' do
    before { recipient_instance }

    context 'with pending messages' do
      before do
        # Create some pending messages
        DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Message 1', delivered: false)
        DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Message 2', delivered: false)
      end

      it 'delivers all pending messages' do
        count = described_class.deliver_pending(recipient_instance)

        expect(count).to eq(2)
        expect(DirectMessage.where(recipient_id: recipient_character.id, delivered: false).count).to eq(0)
      end

      it 'marks messages as delivered' do
        described_class.deliver_pending(recipient_instance)

        DirectMessage.where(recipient_id: recipient_character.id).each do |dm|
          expect(dm.delivered?).to be true
          expect(dm.delivered_at).not_to be_nil
        end
      end
    end

    context 'with no pending messages' do
      it 'returns zero' do
        count = described_class.deliver_pending(recipient_instance)

        expect(count).to eq(0)
      end
    end

    context 'when character is offline' do
      before do
        recipient_instance.update(online: false)
      end

      it 'returns zero without delivering' do
        DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Pending', delivered: false)

        count = described_class.deliver_pending(recipient_instance)

        expect(count).to eq(0)
      end
    end
  end

  describe 'DM delivery — notification metadata' do
    let(:dm_portrait_url) { '/uploads/portraits/alice.jpg' }

    before do
      allow(BroadcastService).to receive(:to_character)
      allow(IcActivityService).to receive(:record_targeted)
      allow(IcActivityService).to receive(:record_for)
      allow_any_instance_of(Character).to receive(:profile_pic_url).and_return(dm_portrait_url)
      sender_instance    # ensure sender is online (forces lazy let evaluation)
      recipient_instance # ensure recipient is online
    end

    context 'when recipient knows the sender' do
      before do
        CharacterKnowledge.create(
          knower_character_id: recipient_character.id,
          known_character_id: sender_character.id,
          is_known: true,
          known_name: 'Alice'
        )
      end

      it 'includes sender_portrait_url in the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_including(sender_portrait_url: dm_portrait_url)
        )
      end

      it 'includes sender_display_name in the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_including(sender_display_name: be_a(String))
        )
      end
    end

    context 'when recipient does not know the sender (is_known false)' do
      before do
        CharacterKnowledge.create(
          knower_character_id: recipient_character.id,
          known_character_id: sender_character.id,
          is_known: false
        )
      end

      it 'omits sender_portrait_url from the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_excluding(:sender_portrait_url)
        )
      end

      it 'omits sender_display_name from the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_excluding(:sender_display_name)
        )
      end
    end

    context 'when no CharacterKnowledge record exists' do
      it 'omits sender_portrait_url from the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_excluding(:sender_portrait_url)
        )
      end

      it 'omits sender_display_name from the broadcast opts' do
        described_class.send_message(sender_instance, recipient_character, 'Hey!')

        expect(BroadcastService).to have_received(:to_character).with(
          anything,
          anything,
          hash_excluding(:sender_display_name)
        )
      end
    end
  end

  describe '.pending_count' do
    before { recipient_instance }

    it 'returns count of pending messages' do
      DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Msg 1', delivered: false)
      DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Msg 2', delivered: false)
      DirectMessage.create(sender_id: sender_character.id, recipient_id: recipient_character.id, content: 'Msg 3', delivered: true)

      count = described_class.pending_count(recipient_character)

      expect(count).to eq(2)
    end

    it 'returns zero when no pending messages' do
      count = described_class.pending_count(recipient_character)

      expect(count).to eq(0)
    end
  end
end
