# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NotificationService do
  let(:user) do
    double('User',
           discord_configured?: true,
           discord_webhook_configured?: true,
           discord_webhook_url: 'https://discord.com/api/webhooks/123/abc',
           should_notify_discord?: true)
  end

  let(:character) do
    double('Character',
           id: 1,
           user: user,
           full_name: 'Alice Smith',
           character_instances_dataset: instances_dataset)
  end

  let(:instances_dataset) do
    dataset = double('Dataset')
    allow(dataset).to receive(:where).and_return(dataset)
    allow(dataset).to receive(:first).and_return(nil)
    dataset
  end

  let(:recipient_instance) do
    double('CharacterInstance',
           character: character)
  end

  describe '.notify_memo' do
    let(:sender) { double('Character', full_name: 'Bob Jones') }
    let(:memo) do
      double('Memo',
             sender_id: 2,
             subject: 'Hello!',
             content: 'This is a test memo.')
    end

    before do
      allow(Character).to receive(:[]).with(2).and_return(sender)
    end

    context 'when recipient and memo are valid' do
      before do
        allow(DiscordWebhookService).to receive(:send).and_return(true)
      end

      it 'sends notification via discord webhook' do
        expect(DiscordWebhookService).to receive(:send).with(
          'https://discord.com/api/webhooks/123/abc',
          hash_including(title: 'New memo from Bob Jones', event_type: :memo)
        )

        described_class.notify_memo(recipient_instance, memo)
      end

      it 'includes memo subject and text in body' do
        expect(DiscordWebhookService).to receive(:send).with(
          anything,
          hash_including(body: include('Subject:', 'Hello!', 'This is a test memo.'))
        )

        described_class.notify_memo(recipient_instance, memo)
      end
    end

    context 'when recipient is nil' do
      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_memo(nil, memo)
      end
    end

    context 'when memo is nil' do
      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_memo(recipient_instance, nil)
      end
    end

    context 'when user does not exist' do
      before do
        allow(character).to receive(:user).and_return(nil)
      end

      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_memo(recipient_instance, memo)
      end
    end

    context 'when user should not be notified' do
      before do
        allow(user).to receive(:should_notify_discord?).and_return(false)
      end

      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_memo(recipient_instance, memo)
      end
    end

    context 'when sender is unknown' do
      before do
        allow(Character).to receive(:[]).with(2).and_return(nil)
        allow(DiscordWebhookService).to receive(:send).and_return(true)
      end

      it 'uses Unknown as sender name' do
        expect(DiscordWebhookService).to receive(:send).with(
          anything,
          hash_including(title: 'New memo from Unknown')
        )

        described_class.notify_memo(recipient_instance, memo)
      end
    end
  end

  describe '.notify_pm' do
    before do
      allow(DiscordWebhookService).to receive(:send).and_return(true)
    end

    context 'with valid parameters' do
      it 'sends notification via discord webhook' do
        expect(DiscordWebhookService).to receive(:send).with(
          'https://discord.com/api/webhooks/123/abc',
          hash_including(title: 'Private message from Bob', event_type: :pm)
        )

        described_class.notify_pm(recipient_instance, 'Bob', 'Hello there!')
      end

      it 'includes message content in body' do
        expect(DiscordWebhookService).to receive(:send).with(
          anything,
          hash_including(body: 'Hello there!')
        )

        described_class.notify_pm(recipient_instance, 'Bob', 'Hello there!')
      end
    end

    context 'when recipient_instance is nil' do
      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_pm(nil, 'Bob', 'Hello')
      end
    end

    context 'when character is nil' do
      before do
        allow(recipient_instance).to receive(:character).and_return(nil)
      end

      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_pm(recipient_instance, 'Bob', 'Hello')
      end
    end

    context 'when user should not be notified for PMs' do
      before do
        allow(user).to receive(:should_notify_discord?).with(recipient_instance, :pm).and_return(false)
      end

      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_pm(recipient_instance, 'Bob', 'Hello')
      end
    end
  end

  describe '.notify_mention' do
    let(:emoting_character) { double('Character', full_name: 'Charlie Brown') }

    before do
      allow(DiscordWebhookService).to receive(:send).and_return(true)
    end

    context 'with valid parameters' do
      it 'sends notification via discord webhook' do
        expect(DiscordWebhookService).to receive(:send).with(
          'https://discord.com/api/webhooks/123/abc',
          hash_including(title: 'Charlie Brown mentioned you', event_type: :mention)
        )

        described_class.notify_mention(recipient_instance, 'waves to Alice', emoting_character)
      end

      it 'includes emote text in body' do
        expect(DiscordWebhookService).to receive(:send).with(
          anything,
          hash_including(body: 'waves to Alice')
        )

        described_class.notify_mention(recipient_instance, 'waves to Alice', emoting_character)
      end
    end

    context 'when recipient_instance is nil' do
      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_mention(nil, 'waves', emoting_character)
      end
    end

    context 'when emoting_character is nil' do
      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_mention(recipient_instance, 'waves', nil)
      end
    end

    context 'when user should not be notified for mentions' do
      before do
        allow(user).to receive(:should_notify_discord?).with(recipient_instance, :mention).and_return(false)
      end

      it 'returns early' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.notify_mention(recipient_instance, 'waves', emoting_character)
      end
    end
  end

  describe '.send_test' do
    context 'when user has discord configured' do
      before do
        allow(DiscordWebhookService).to receive(:send).and_return(true)
      end

      it 'sends test notification' do
        expect(DiscordWebhookService).to receive(:send).with(
          'https://discord.com/api/webhooks/123/abc',
          hash_including(title: 'Test Notification', event_type: :test)
        )

        described_class.send_test(user)
      end

      it 'returns true on success' do
        expect(described_class.send_test(user)).to be true
      end
    end

    context 'when user is nil' do
      it 'returns false' do
        expect(described_class.send_test(nil)).to be false
      end
    end

    context 'when discord is not configured' do
      before do
        allow(user).to receive(:discord_configured?).and_return(false)
      end

      it 'returns false' do
        expect(described_class.send_test(user)).to be false
      end
    end

    context 'when webhook delivery fails' do
      before do
        allow(DiscordWebhookService).to receive(:send).and_return(false)
      end

      it 'returns false' do
        expect(described_class.send_test(user)).to be false
      end
    end
  end

  describe '.deliver (private)' do
    context 'when webhook is not configured' do
      before do
        allow(user).to receive(:discord_webhook_configured?).and_return(false)
      end

      it 'does not call webhook service' do
        expect(DiscordWebhookService).not_to receive(:send)

        described_class.send(:deliver, user, 'Title', 'Body', :test)
      end

      it 'returns false' do
        result = described_class.send(:deliver, user, 'Title', 'Body', :test)

        expect(result).to be false
      end
    end
  end
end
