# frozen_string_literal: true

module Commands
  module System
    class Discord < ::Commands::Base::Command
      command_name 'discord'
      category :system
      help_text 'Configure Discord notifications for offline messages and mentions'
      usage 'discord [setting] [value]'
      examples 'discord',
               'discord webhook https://discord.com/api/webhooks/...',
               'discord webhook clear',
               'discord offline on',
               'discord memos off',
               'discord test'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip || ''
        args = text.split(/\s+/, 2)

        case args[0]&.downcase
        when nil, ''
          # No args = show settings form
          show_discord_form
        when 'status'
          show_status
        when 'webhook'
          handle_webhook(args[1])
        when 'username', 'handle'
          handle_username(args[1])
        when 'offline'
          toggle_setting(:discord_notify_offline, args[1], 'offline notifications')
        when 'online'
          toggle_setting(:discord_notify_online, args[1], 'online notifications')
        when 'memos'
          toggle_setting(:discord_notify_memos, args[1], 'memo notifications')
        when 'pms'
          toggle_setting(:discord_notify_pms, args[1], 'PM notifications')
        when 'mentions'
          toggle_setting(:discord_notify_mentions, args[1], 'mention notifications')
        when 'test'
          send_test
        when 'help'
          show_help_text
        else
          error_result("Unknown setting '#{args[0]}'. Use 'discord help' for options.")
        end
      end

      # Handle form submission
      def handle_form_response(form_data, _context)
        # Handle webhook URL
        webhook_url = form_data['webhook_url']&.strip
        if webhook_url && !webhook_url.empty?
          unless DiscordWebhookService.valid_webhook_url?(webhook_url)
            return error_result("Invalid webhook URL. It should look like:\nhttps://discord.com/api/webhooks/123456/abcdef...")
          end
          user.update(discord_webhook_url: webhook_url)
        elsif form_data['clear_webhook'] == 'true'
          user.update(discord_webhook_url: nil)
        end

        # Handle Discord handle
        username_input = form_data['username'] || form_data['handle']
        username = username_input&.strip
        if username && !username.empty?
          normalized_handle = User.normalize_discord_handle(username)
          return error_result(User::DISCORD_HANDLE_ERROR) unless normalized_handle

          user.update(discord_username: normalized_handle)
        elsif form_data['clear_username'] == 'true'
          user.update(discord_username: nil)
        end

        # Apply notification toggles
        user.update(
          discord_notify_offline: form_data['notify_offline'] == 'true',
          discord_notify_online: form_data['notify_online'] == 'true',
          discord_notify_memos: form_data['notify_memos'] == 'true',
          discord_notify_pms: form_data['notify_pms'] == 'true',
          discord_notify_mentions: form_data['notify_mentions'] == 'true'
        )

        success_result(
          "Discord settings updated.",
          type: :system,
          data: { settings_updated: true }
        )
      end

      private

      def user
        @user ||= character&.user
      end

      def show_discord_form
        settings = user.discord_settings

        fields = [
          {
            name: 'webhook_url',
            label: 'Webhook URL',
            type: 'text',
            required: false,
            default: settings[:webhook_url] || '',
            placeholder: 'https://discord.com/api/webhooks/...',
            description: 'Get from Discord: Server Settings > Integrations > Webhooks'
          },
          {
            name: 'username',
            label: 'Discord Handle',
            type: 'text',
            required: false,
            default: settings[:username] || '',
            placeholder: '@your_handle',
            description: 'For bot DMs (coming soon). Use Discord @handle format.'
          },
          {
            name: 'notify_offline',
            label: 'Notify When Offline',
            type: 'checkbox',
            default: settings[:notify_offline] ? 'true' : 'false',
            description: 'Send notifications when you are offline'
          },
          {
            name: 'notify_online',
            label: 'Notify When Online',
            type: 'checkbox',
            default: settings[:notify_online] ? 'true' : 'false',
            description: 'Also send notifications when you are online'
          },
          {
            name: 'notify_memos',
            label: 'Notify on Memos',
            type: 'checkbox',
            default: settings[:notify_memos] ? 'true' : 'false',
            description: 'Receive notifications for new memos'
          },
          {
            name: 'notify_pms',
            label: 'Notify on Private Messages',
            type: 'checkbox',
            default: settings[:notify_pms] ? 'true' : 'false',
            description: 'Receive notifications for private messages'
          },
          {
            name: 'notify_mentions',
            label: 'Notify on RP Mentions',
            type: 'checkbox',
            default: settings[:notify_mentions] ? 'true' : 'false',
            description: 'Receive notifications when mentioned in RP'
          }
        ]

        create_form(
          character_instance,
          'Discord Notifications',
          fields,
          context: {
            command: 'discord'
          }
        )
      end

      def show_status
        settings = user.discord_settings

        lines = []
        lines << "Discord Notification Settings"
        lines << "-" * 30

        # Webhook status
        if settings[:webhook_url] && !settings[:webhook_url].to_s.empty?
          # Mask the webhook URL for privacy
          lines << "Webhook: Configured (ending in ...#{settings[:webhook_url][-20..]})"
        else
          lines << "Webhook: Not configured"
        end

        # Handle status (Phase 2)
        if settings[:username] && !settings[:username].to_s.empty?
          lines << "Handle: #{settings[:username]} (bot DMs)"
        else
          lines << "Handle: Not configured (for bot DMs)"
        end

        lines << ""
        lines << "When to notify:"
        lines << "  Offline: #{settings[:notify_offline] ? 'Yes' : 'No'}"
        lines << "  Online:  #{settings[:notify_online] ? 'Yes' : 'No'}"

        lines << ""
        lines << "What to notify:"
        lines << "  Memos:    #{settings[:notify_memos] ? 'Yes' : 'No'}"
        lines << "  PMs:      #{settings[:notify_pms] ? 'Yes' : 'No'}"
        lines << "  Mentions: #{settings[:notify_mentions] ? 'Yes' : 'No'}"

        lines << ""
        lines << "Use 'discord help' for configuration commands."

        success_result(lines.join("\n"))
      end

      def handle_webhook(value)
        if value.nil? || value.empty?
          return error_result("Provide a webhook URL. Get one from Discord: Server Settings > Integrations > Webhooks")
        end

        if value.downcase == 'clear'
          user.update(discord_webhook_url: nil)
          return success_result("Discord webhook removed.")
        end

        unless DiscordWebhookService.valid_webhook_url?(value)
          return error_result("Invalid webhook URL. It should look like:\nhttps://discord.com/api/webhooks/123456/abcdef...")
        end

        user.update(discord_webhook_url: value)
        success_result("Discord webhook configured. Use 'discord test' to verify it works.")
      end

      def handle_username(value)
        if value.nil? || value.empty?
          return error_result('Provide your Discord handle for bot DMs.')
        end

        if value.downcase == 'clear'
          user.update(discord_username: nil)
          return success_result('Discord handle removed.')
        end

        normalized_handle = User.normalize_discord_handle(value)
        return error_result(User::DISCORD_HANDLE_ERROR) unless normalized_handle

        user.update(discord_username: normalized_handle)
        success_result("Discord handle set to '#{normalized_handle}'. Bot DM support coming soon.")
      end

      def toggle_setting(field, value, description)
        if value.nil? || value.empty?
          current = user.send(field)
          return success_result("#{description.capitalize}: #{current ? 'On' : 'Off'}")
        end

        case value.downcase
        when 'on', 'yes', 'true', '1'
          user.update(field => true)
          success_result("#{description.capitalize} enabled.")
        when 'off', 'no', 'false', '0'
          user.update(field => false)
          success_result("#{description.capitalize} disabled.")
        else
          error_result("Use 'on' or 'off' to toggle #{description}.")
        end
      end

      def send_test
        unless user.discord_configured?
          return error_result("Configure Discord first. Use 'discord webhook <url>' to set up.")
        end

        if NotificationService.send_test(user)
          success_result("Test notification sent! Check your Discord.")
        else
          error_result("Failed to send test notification. Check your webhook URL.")
        end
      end

      def show_help_text
        lines = []
        lines << "Discord Notification Commands"
        lines << "-" * 30
        lines << ""
        lines << "discord              - Show current settings"
        lines << "discord webhook <url> - Set webhook URL"
        lines << "discord webhook clear - Remove webhook"
        lines << "discord handle <@name> - Set Discord handle for bot DMs"
        lines << "discord handle clear - Remove Discord handle"
        lines << "discord username ...  - Alias for 'discord handle'"
        lines << ""
        lines << "discord offline on/off - Toggle offline notifications"
        lines << "discord online on/off  - Toggle online notifications"
        lines << "discord memos on/off   - Toggle memo notifications"
        lines << "discord pms on/off     - Toggle PM notifications"
        lines << "discord mentions on/off - Toggle RP mention notifications"
        lines << ""
        lines << "discord test - Send a test notification"
        lines << ""
        lines << "To get a webhook URL:"
        lines << "1. Open Discord Server Settings"
        lines << "2. Go to Integrations > Webhooks"
        lines << "3. Create New Webhook"
        lines << "4. Copy Webhook URL"

        success_result(lines.join("\n"))
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Discord)
