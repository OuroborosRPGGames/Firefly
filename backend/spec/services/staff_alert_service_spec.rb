# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StaffAlertService do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end

    it 'is not a class' do
      expect(described_class).not_to be_a(Class)
    end
  end

  describe 'constants' do
    it 'defines DISCORD_COLOR' do
      expect(described_class::DISCORD_COLOR).to eq(0xe74c3c)
    end
  end

  describe 'class methods' do
    it 'defines send_trigger_alert' do
      expect(described_class).to respond_to(:send_trigger_alert)
    end

    it 'defines broadcast_to_staff' do
      expect(described_class).to respond_to(:broadcast_to_staff)
    end
  end

  describe '.send_trigger_alert signature' do
    it 'accepts keyword parameters' do
      method = described_class.method(:send_trigger_alert)
      params = method.parameters.map(&:last)
      expect(params).to include(:trigger)
      expect(params).to include(:activation)
    end

    it 'accepts optional send_discord parameter' do
      method = described_class.method(:send_trigger_alert)
      params = method.parameters.map(&:last)
      expect(params).to include(:send_discord)
    end

    it 'accepts optional send_email parameter' do
      method = described_class.method(:send_trigger_alert)
      params = method.parameters.map(&:last)
      expect(params).to include(:send_email)
    end

    it 'accepts optional email_recipients parameter' do
      method = described_class.method(:send_trigger_alert)
      params = method.parameters.map(&:last)
      expect(params).to include(:email_recipients)
    end
  end

  describe '.broadcast_to_staff signature' do
    it 'accepts message parameter' do
      method = described_class.method(:broadcast_to_staff)
      params = method.parameters.map(&:last)
      expect(params).to include(:message)
    end
  end

  describe '.broadcast_to_staff' do
    before do
      allow(BroadcastService).to receive(:to_character)
    end

    context 'with online staff' do
      let(:admin_user) { double('User', admin?: true) }
      let(:staff_character) { double('Character', staff?: false, user: admin_user) }
      let(:staff_instance) { double('CharacterInstance', character: staff_character) }

      before do
        eager_dataset = double('EagerDataset', all: [staff_instance])
        where_dataset = double('WhereDataset', eager: eager_dataset)
        allow(CharacterInstance).to receive(:where).with(online: true).and_return(where_dataset)
      end

      it 'broadcasts message to online staff characters' do
        described_class.broadcast_to_staff('Test alert')
        expect(BroadcastService).to have_received(:to_character).with(
          staff_instance,
          hash_including(content: '[STAFF ALERT] Test alert'),
          type: :staff_alert
        )
      end

      it 'returns count of staff notified' do
        result = described_class.broadcast_to_staff('Test alert')
        expect(result).to eq(1)
      end
    end

    context 'with no online staff' do
      before do
        eager_dataset = double('EagerDataset', all: [])
        where_dataset = double('WhereDataset', eager: eager_dataset)
        allow(CharacterInstance).to receive(:where).with(online: true).and_return(where_dataset)
      end

      it 'does not broadcast' do
        described_class.broadcast_to_staff('Test alert')
        expect(BroadcastService).not_to have_received(:to_character)
      end

      it 'returns 0 when no staff online' do
        result = described_class.broadcast_to_staff('Test alert')
        expect(result).to eq(0)
      end
    end

    context 'with mixed online users' do
      let(:normal_user) { double('User', admin?: false) }
      let(:normal_character) { double('Character', staff?: false, user: normal_user) }
      let(:normal_instance) { double('CharacterInstance', character: normal_character) }

      before do
        eager_dataset = double('EagerDataset', all: [normal_instance])
        where_dataset = double('WhereDataset', eager: eager_dataset)
        allow(CharacterInstance).to receive(:where).with(online: true).and_return(where_dataset)
      end

      it 'does not broadcast to non-staff characters' do
        described_class.broadcast_to_staff('Test alert')
        expect(BroadcastService).not_to have_received(:to_character)
      end
    end
  end

  describe '.send_trigger_alert' do
    let(:trigger) do
      double('Trigger',
        name: 'Test Trigger',
        trigger_type: 'emote',
        alert_message_template: nil
      )
    end
    let(:source_character) do
      double('Character', full_name: 'Test Character')
    end
    let(:activation) do
      double('TriggerActivation',
        source_character: source_character,
        source_type: 'emote',
        triggering_content: 'test content',
        activated_at: Time.now,
        llm_confidence: nil,
        confidence_percentage: nil,
        clue: nil,
        clue_recipient: nil
      )
    end

    before do
      allow(described_class).to receive(:broadcast_to_staff)
    end

    it 'always broadcasts to staff' do
      described_class.send_trigger_alert(trigger: trigger, activation: activation)
      expect(described_class).to have_received(:broadcast_to_staff).with(anything)
    end

    context 'with default message' do
      it 'builds message from trigger and activation' do
        described_class.send_trigger_alert(trigger: trigger, activation: activation)
        expect(described_class).to have_received(:broadcast_to_staff).with(
          include("Trigger 'Test Trigger'")
        )
      end

      it 'includes source character name' do
        described_class.send_trigger_alert(trigger: trigger, activation: activation)
        expect(described_class).to have_received(:broadcast_to_staff).with(
          include('Test Character')
        )
      end
    end

    context 'with custom template' do
      let(:trigger_with_template) do
        double('Trigger',
          name: 'Template Trigger',
          trigger_type: 'emote',
          alert_message_template: '{{trigger_name}} fired by {{source}}'
        )
      end

      it 'uses template with interpolation' do
        described_class.send_trigger_alert(trigger: trigger_with_template, activation: activation)
        expect(described_class).to have_received(:broadcast_to_staff).with(
          'Template Trigger fired by Test Character'
        )
      end
    end

    context 'with LLM confidence' do
      let(:activation_with_confidence) do
        double('TriggerActivation',
          source_character: source_character,
          source_type: 'emote',
          triggering_content: 'test',
          activated_at: Time.now,
          llm_confidence: 0.85,
          confidence_percentage: '85%',
          clue: nil,
          clue_recipient: nil
        )
      end

      it 'includes confidence in message' do
        described_class.send_trigger_alert(trigger: trigger, activation: activation_with_confidence)
        expect(described_class).to have_received(:broadcast_to_staff).with(
          include('85%')
        )
      end
    end

    context 'with send_discord enabled' do
      before do
        allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return(nil)
      end

      it 'does not send if no webhook configured' do
        expect(Faraday).not_to receive(:post)
        described_class.send_trigger_alert(trigger: trigger, activation: activation, send_discord: true)
      end

      context 'with webhook configured' do
        let(:webhook_url) { 'https://discord.com/api/webhooks/test' }
        let(:mock_response) { double('Response', status: 200) }

        before do
          allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return(webhook_url)
          allow(GameSetting).to receive(:get).with('game_name').and_return('Firefly')
          allow(Faraday).to receive(:post).and_return(mock_response)
        end

        it 'sends Discord webhook' do
          described_class.send_trigger_alert(trigger: trigger, activation: activation, send_discord: true)
          expect(Faraday).to have_received(:post).with(webhook_url)
        end
      end
    end

    context 'with send_email enabled' do
      before do
        allow(EmailService).to receive(:configured?).and_return(false)
      end

      it 'does not send if email not configured' do
        expect(EmailService).not_to receive(:send_email)
        described_class.send_trigger_alert(
          trigger: trigger,
          activation: activation,
          send_email: true,
          email_recipients: 'test@example.com'
        )
      end

      context 'with email configured' do
        before do
          allow(EmailService).to receive(:configured?).and_return(true)
          allow(EmailService).to receive(:send_email).and_return(true)
        end

        it 'sends email to recipients' do
          described_class.send_trigger_alert(
            trigger: trigger,
            activation: activation,
            send_email: true,
            email_recipients: 'test@example.com'
          )
          expect(EmailService).to have_received(:send_email).with(
            hash_including(to: 'test@example.com')
          )
        end

        it 'handles multiple recipients' do
          described_class.send_trigger_alert(
            trigger: trigger,
            activation: activation,
            send_email: true,
            email_recipients: 'one@example.com, two@example.com'
          )
          expect(EmailService).to have_received(:send_email).twice
        end

        it 'skips empty recipients' do
          described_class.send_trigger_alert(
            trigger: trigger,
            activation: activation,
            send_email: true,
            email_recipients: ''
          )
          expect(EmailService).not_to have_received(:send_email)
        end
      end
    end
  end

  describe 'template interpolation' do
    let(:trigger) do
      double('Trigger',
        name: 'Test Trigger',
        trigger_type: 'clue_share',
        alert_message_template: '{{trigger_name}} - {{trigger_type}} - {{source}} - {{content}}'
      )
    end
    let(:clue) { double('Clue', name: 'Secret Clue') }
    let(:recipient) { double('Character', full_name: 'Recipient Name') }
    let(:source_char) { double('Character', full_name: 'Source Name') }
    let(:activation) do
      double('TriggerActivation',
        source_character: source_char,
        source_type: 'clue_share',
        triggering_content: 'The secret message content',
        activated_at: Time.parse('2024-01-15 14:30:00'),
        llm_confidence: nil,
        confidence_percentage: nil,
        clue: clue,
        clue_recipient: recipient
      )
    end

    before do
      allow(described_class).to receive(:broadcast_to_staff)
    end

    it 'interpolates all standard placeholders' do
      described_class.send_trigger_alert(trigger: trigger, activation: activation)
      expect(described_class).to have_received(:broadcast_to_staff).with(
        'Test Trigger - clue_share - Source Name - The secret message content'
      )
    end

    context 'with clue-specific placeholders' do
      let(:clue_trigger) do
        double('Trigger',
          name: 'Clue Alert',
          trigger_type: 'clue_share',
          alert_message_template: 'Clue {{clue_name}} shared with {{clue_recipient}}'
        )
      end

      it 'interpolates clue placeholders' do
        described_class.send_trigger_alert(trigger: clue_trigger, activation: activation)
        expect(described_class).to have_received(:broadcast_to_staff).with(
          'Clue Secret Clue shared with Recipient Name'
        )
      end
    end

    context 'with missing source character' do
      let(:system_activation) do
        double('TriggerActivation',
          source_character: nil,
          source_type: 'system',
          triggering_content: 'System event',
          activated_at: Time.now,
          llm_confidence: nil,
          confidence_percentage: nil,
          clue: nil,
          clue_recipient: nil
        )
      end

      it 'uses System as default source' do
        simple_trigger = double('Trigger',
          name: 'System Trigger',
          trigger_type: 'system',
          alert_message_template: 'Alert from {{source}}'
        )
        described_class.send_trigger_alert(trigger: simple_trigger, activation: system_activation)
        expect(described_class).to have_received(:broadcast_to_staff).with('Alert from System')
      end
    end
  end

  describe 'Discord embed building' do
    let(:trigger) do
      double('Trigger',
        name: 'Discord Test',
        trigger_type: 'emote',
        alert_message_template: nil
      )
    end
    let(:source_char) { double('Character', full_name: 'Test Player') }
    let(:clue) { double('Clue', name: 'Important Clue') }
    let(:recipient) { double('Character', full_name: 'Recipient') }
    let(:activation) do
      double('TriggerActivation',
        source_character: source_char,
        source_type: 'emote',
        triggering_content: 'test',
        activated_at: Time.now,
        llm_confidence: 0.92,
        confidence_percentage: '92%',
        clue: clue,
        clue_recipient: recipient
      )
    end
    let(:captured_payload) { [] }

    before do
      allow(described_class).to receive(:broadcast_to_staff)
      allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return('https://discord.com/test')
      allow(GameSetting).to receive(:get).with('game_name').and_return('Firefly')
      allow(Faraday).to receive(:post) do |_url, &block|
        # Capture the payload
        request = double('Request')
        request_body = nil
        allow(request).to receive(:headers).and_return({})
        allow(request).to receive(:body=) { |b| request_body = b }
        allow(request).to receive(:options).and_return(double(timeout: nil, 'timeout=' => nil))
        block.call(request) if block
        captured_payload << JSON.parse(request_body) if request_body
        double('Response', status: 200)
      end
    end

    it 'includes all embed fields for full activation' do
      described_class.send_trigger_alert(trigger: trigger, activation: activation, send_discord: true)

      expect(captured_payload).not_to be_empty
      embed = captured_payload.first['embeds'].first
      field_names = embed['fields'].map { |f| f['name'] }

      expect(field_names).to include('Trigger Type')
      expect(field_names).to include('Source')
      expect(field_names).to include('Character')
      expect(field_names).to include('LLM Confidence')
      expect(field_names).to include('Clue')
      expect(field_names).to include('Recipient')
    end
  end

  describe 'error handling' do
    let(:trigger) do
      double('Trigger',
        name: 'Test',
        trigger_type: 'emote',
        alert_message_template: nil
      )
    end
    let(:activation) do
      double('TriggerActivation',
        source_character: nil,
        source_type: 'system',
        triggering_content: nil,
        activated_at: nil,
        llm_confidence: nil,
        confidence_percentage: nil,
        clue: nil,
        clue_recipient: nil
      )
    end

    before do
      allow(described_class).to receive(:broadcast_to_staff)
    end

    context 'Discord webhook failure' do
      before do
        allow(GameSetting).to receive(:get).with('staff_discord_webhook').and_return('https://discord.com/test')
        allow(GameSetting).to receive(:get).with('game_name').and_return('Firefly')
        allow(Faraday).to receive(:post).and_raise(Faraday::ConnectionFailed.new('connection failed'))
      end

      it 'logs error and continues' do
        expect {
          described_class.send_trigger_alert(trigger: trigger, activation: activation, send_discord: true)
        }.not_to raise_error
      end
    end

    context 'email failure' do
      before do
        allow(EmailService).to receive(:configured?).and_return(true)
        allow(EmailService).to receive(:send_email).and_raise(StandardError.new('email error'))
      end

      it 'logs error and continues' do
        expect {
          described_class.send_trigger_alert(
            trigger: trigger,
            activation: activation,
            send_email: true,
            email_recipients: 'test@example.com'
          )
        }.not_to raise_error
      end
    end
  end
end
