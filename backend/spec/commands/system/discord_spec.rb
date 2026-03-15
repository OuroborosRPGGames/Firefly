# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Discord do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Test', surname: 'User') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'discord' : "discord #{args}"
    command.execute(input)
  end

  let(:discord_settings) do
    {
      webhook_url: nil,
      username: nil,
      notify_offline: false,
      notify_online: false,
      notify_memos: false,
      notify_pms: false,
      notify_mentions: false
    }
  end

  before do
    allow(user).to receive(:discord_settings).and_return(discord_settings)
    allow(user).to receive(:update).and_return(true)
  end

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['discord']).to eq(described_class)
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:system)
    end
  end

  describe 'subcommand: (none) - show form' do
    it 'shows discord settings form' do
      result = execute_command

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:form)
      expect(result[:data][:title]).to include('Discord')
    end

    it 'includes webhook field' do
      result = execute_command

      fields = result[:data][:fields]
      webhook_field = fields.find { |f| f[:name] == 'webhook_url' }

      expect(webhook_field).not_to be_nil
      expect(webhook_field[:type]).to eq('text')
    end

    it 'includes notification toggle fields' do
      result = execute_command

      fields = result[:data][:fields]
      field_names = fields.map { |f| f[:name] }

      expect(field_names).to include('notify_offline')
      expect(field_names).to include('notify_memos')
      expect(field_names).to include('notify_pms')
      expect(field_names).to include('notify_mentions')
    end
  end

  describe 'subcommand: status' do
    context 'with no webhook configured' do
      it 'shows not configured' do
        result = execute_command('status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Webhook: Not configured')
      end
    end

    context 'with webhook configured' do
      let(:discord_settings) do
        {
          webhook_url: 'https://discord.com/api/webhooks/123456789/abcdefghijklmnop',
          username: nil,
          notify_offline: true,
          notify_online: false,
          notify_memos: true,
          notify_pms: false,
          notify_mentions: true
        }
      end

      it 'shows webhook configured (masked)' do
        result = execute_command('status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Webhook: Configured')
        # Should show last 20 chars
        expect(result[:message]).to include('...')
      end

      it 'shows notification settings' do
        result = execute_command('status')

        expect(result[:message]).to include('Offline: Yes')
        expect(result[:message]).to include('Online:  No')
        expect(result[:message]).to include('Memos:    Yes')
        expect(result[:message]).to include('PMs:      No')
        expect(result[:message]).to include('Mentions: Yes')
      end
    end

    context 'with username configured' do
      let(:discord_settings) do
        {
          webhook_url: nil,
          username: '@testuser',
          notify_offline: false,
          notify_online: false,
          notify_memos: false,
          notify_pms: false,
          notify_mentions: false
        }
      end

      it 'shows username' do
        result = execute_command('status')

        expect(result[:message]).to include('Handle: @testuser')
      end
    end
  end

  describe 'subcommand: webhook' do
    context 'without value' do
      it 'returns error' do
        result = execute_command('webhook')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Provide a webhook URL')
      end
    end

    context 'with clear' do
      it 'clears webhook' do
        expect(user).to receive(:update).with(discord_webhook_url: nil)

        result = execute_command('webhook clear')

        expect(result[:success]).to be true
        expect(result[:message]).to include('webhook removed')
      end
    end

    context 'with invalid URL' do
      before do
        allow(DiscordWebhookService).to receive(:valid_webhook_url?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('webhook https://invalid.url')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid webhook URL')
      end
    end

    context 'with valid URL' do
      let(:valid_url) { 'https://discord.com/api/webhooks/123456789/abcdefghijklmnop' }

      before do
        allow(DiscordWebhookService).to receive(:valid_webhook_url?).and_return(true)
      end

      it 'saves webhook' do
        expect(user).to receive(:update).with(discord_webhook_url: valid_url)

        result = execute_command("webhook #{valid_url}")

        expect(result[:success]).to be true
        expect(result[:message]).to include('webhook configured')
      end

      it 'suggests test' do
        result = execute_command("webhook #{valid_url}")

        expect(result[:message]).to include('discord test')
      end
    end
  end

  describe 'subcommand: handle' do
    context 'without value' do
      it 'returns error' do
        result = execute_command('handle')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Provide your Discord handle')
      end
    end

    context 'with clear' do
      it 'clears username' do
        expect(user).to receive(:update).with(discord_username: nil)

        result = execute_command('handle clear')

        expect(result[:success]).to be true
        expect(result[:message]).to include('handle removed')
      end
    end

    context 'with handle' do
      it 'saves normalized handle' do
        expect(user).to receive(:update).with(discord_username: '@test.user')

        result = execute_command('handle Test.User')

        expect(result[:success]).to be true
        expect(result[:message]).to include("handle set to '@test.user'")
      end

      it 'supports username alias' do
        expect(user).to receive(:update).with(discord_username: '@testuser')

        result = execute_command('username TestUser')

        expect(result[:success]).to be true
      end

      it 'rejects legacy discriminator format' do
        expect(user).not_to receive(:update).with(discord_username: anything)

        result = execute_command('handle LegacyName#1234')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid Discord handle')
      end
    end
  end

  describe 'toggle settings' do
    %w[offline online memos pms mentions].each do |setting|
      describe "subcommand: #{setting}" do
        context 'without value' do
          it 'shows current setting' do
            allow(user).to receive(:"discord_notify_#{setting}").and_return(true)

            result = execute_command(setting)

            expect(result[:success]).to be true
            expect(result[:message]).to match(/on/i)
          end
        end

        context 'with on' do
          it 'enables setting' do
            expect(user).to receive(:update).with(:"discord_notify_#{setting}" => true)

            result = execute_command("#{setting} on")

            expect(result[:success]).to be true
            expect(result[:message]).to include('enabled')
          end
        end

        context 'with off' do
          it 'disables setting' do
            expect(user).to receive(:update).with(:"discord_notify_#{setting}" => false)

            result = execute_command("#{setting} off")

            expect(result[:success]).to be true
            expect(result[:message]).to include('disabled')
          end
        end

        context 'with yes/no' do
          it 'handles yes' do
            expect(user).to receive(:update).with(:"discord_notify_#{setting}" => true)

            result = execute_command("#{setting} yes")

            expect(result[:success]).to be true
          end

          it 'handles no' do
            expect(user).to receive(:update).with(:"discord_notify_#{setting}" => false)

            result = execute_command("#{setting} no")

            expect(result[:success]).to be true
          end
        end

        context 'with invalid value' do
          it 'returns error' do
            result = execute_command("#{setting} maybe")

            expect(result[:success]).to be false
            expect(result[:message]).to include('on')
            expect(result[:message]).to include('off')
          end
        end
      end
    end
  end

  describe 'subcommand: test' do
    context 'when discord not configured' do
      before do
        allow(user).to receive(:discord_configured?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('test')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Configure Discord first')
      end
    end

    context 'when discord configured' do
      before do
        allow(user).to receive(:discord_configured?).and_return(true)
      end

      context 'when test succeeds' do
        before do
          allow(NotificationService).to receive(:send_test).with(user).and_return(true)
        end

        it 'returns success' do
          result = execute_command('test')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Test notification sent')
        end
      end

      context 'when test fails' do
        before do
          allow(NotificationService).to receive(:send_test).with(user).and_return(false)
        end

        it 'returns error' do
          result = execute_command('test')

          expect(result[:success]).to be false
          expect(result[:message]).to include('Failed to send')
        end
      end
    end
  end

  describe 'subcommand: help' do
    it 'shows help text' do
      result = execute_command('help')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Discord Notification Commands')
      expect(result[:message]).to include('webhook')
      expect(result[:message]).to include('offline')
      expect(result[:message]).to include('memos')
    end

    it 'includes setup instructions' do
      result = execute_command('help')

      expect(result[:message]).to include('Discord Server Settings')
      expect(result[:message]).to include('Integrations')
      expect(result[:message]).to include('Webhooks')
    end
  end

  describe 'unknown subcommand' do
    it 'returns error' do
      result = execute_command('unknown')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Unknown setting')
      expect(result[:message]).to include('unknown')
    end
  end

  describe 'form submission' do
    let(:form_data) do
      {
        'webhook_url' => 'https://discord.com/api/webhooks/123456789/abcdef',
        'username' => 'Test.User',
        'notify_offline' => 'true',
        'notify_online' => 'false',
        'notify_memos' => 'true',
        'notify_pms' => 'true',
        'notify_mentions' => 'false'
      }
    end

    before do
      allow(DiscordWebhookService).to receive(:valid_webhook_url?).and_return(true)
    end

    it 'updates all settings' do
      expect(user).to receive(:update).with(discord_webhook_url: form_data['webhook_url'])
      expect(user).to receive(:update).with(discord_username: '@test.user')
      expect(user).to receive(:update).with(
        discord_notify_offline: true,
        discord_notify_online: false,
        discord_notify_memos: true,
        discord_notify_pms: true,
        discord_notify_mentions: false
      )

      result = command.send(:handle_form_response, form_data, {})

      expect(result[:success]).to be true
      expect(result[:message]).to include('settings updated')
    end

    context 'with clear_webhook' do
      let(:form_data) do
        {
          'clear_webhook' => 'true',
          'notify_offline' => 'false',
          'notify_online' => 'false',
          'notify_memos' => 'false',
          'notify_pms' => 'false',
          'notify_mentions' => 'false'
        }
      end

      it 'clears webhook' do
        expect(user).to receive(:update).with(discord_webhook_url: nil)

        command.send(:handle_form_response, form_data, {})
      end
    end

    context 'with invalid webhook URL' do
      let(:form_data) do
        {
          'webhook_url' => 'https://invalid.url',
          'notify_offline' => 'false',
          'notify_online' => 'false',
          'notify_memos' => 'false',
          'notify_pms' => 'false',
          'notify_mentions' => 'false'
        }
      end

      before do
        allow(DiscordWebhookService).to receive(:valid_webhook_url?).and_return(false)
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid webhook URL')
      end
    end

    context 'with legacy username format' do
      let(:form_data) do
        {
          'username' => 'LegacyName#1234',
          'notify_offline' => 'false',
          'notify_online' => 'false',
          'notify_memos' => 'false',
          'notify_pms' => 'false',
          'notify_mentions' => 'false'
        }
      end

      it 'returns error' do
        result = command.send(:handle_form_response, form_data, {})

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid Discord handle')
      end
    end
  end
end
