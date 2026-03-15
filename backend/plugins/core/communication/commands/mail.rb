# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'

module Commands
  module Communication
    # Unified mail command.
    # Replaces: send_memo.rb, read_memo.rb, delete_memo.rb
    class Mail < Commands::Base::Command
      include MessagePersistenceHelper

      command_name 'mail'
      aliases 'memo', 'memos', 'email', 'messages', 'inbox'
      category :communication
      help_text 'Read and send memos/mail'
      usage 'mail [subcommand] [arguments]'
      examples(
        'mail',
        'mail list',
        'mail read 1',
        'mail send Alice',
        'mail delete 1',
        'mail delete all'
      )

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        subcommand = args.first&.downcase
        sub_args = args[1..] || []

        case subcommand
        when nil, 'list', 'ls', 'inbox'
          show_inbox
        when 'read', 'view'
          read_memo(sub_args.first)
        when 'send', 'write', 'compose'
          send_memo(sub_args.join(' '))
        when 'delete', 'del', 'remove'
          delete_memo(sub_args.first)
        else
          # Check if it's a number (read shortcut)
          if subcommand =~ /^\d+$/
            read_memo(subcommand)
          else
            show_usage
          end
        end
      end

      # Handle form submission for composing memos
      def handle_form_response(form_data, _context)
        recipient_name = form_data['recipient']&.strip
        subject = form_data['subject']&.strip
        body = form_data['body']&.strip

        recipient_result = resolve_mail_recipient(recipient_name, missing_error: 'Recipient is required.')
        return recipient_result[:error] if recipient_result[:error]
        recipient = recipient_result[:recipient]

        # Validate subject
        error = require_input(subject, 'Subject is required.')
        return error if error

        max_subject = GameConfig::Forms::MAX_LENGTHS[:memo_subject]
        if subject.length > max_subject
          return error_result("Subject too long (max #{max_subject} characters).")
        end

        # Validate body
        error = require_input(body, 'Message body is required.')
        return error if error

        max_body = GameConfig::Forms::MAX_LENGTHS[:memo_body]
        if body.length > max_body
          return error_result("Message too long (max #{max_body.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} characters).")
        end

        # Check for abuse
        full_content = "#{subject}: #{body}"
        abuse_result = check_for_abuse(full_content, message_type: 'memo')
        unless abuse_result[:allowed]
          return error_result(abuse_result[:reason] || 'Your memo is being reviewed.')
        end

        # Send the memo
        do_send_memo(recipient, subject, body)
      end

      private

      # ========================================
      # Inbox / List
      # ========================================

      def show_inbox
        memos = Memo.inbox_for(character).all

        if memos.empty?
          return success_result(
            "Your inbox is empty.\nUse 'mail send <name>' to compose a new memo.",
            type: :message,
            data: { action: 'inbox', count: 0 }
          )
        end

        unread_count = memos.count(&:unread?)

        # Build options for quickmenu
        options = memos.each_with_index.map do |memo, idx|
          sender_name = memo.sender&.full_name || 'Unknown'
          subject = memo.subject || '(no subject)'
          subject = subject[0..30] + '...' if subject.length > 33
          time_ago = format_time_ago(memo.sent_at)

          status = memo.unread? ? "\u25cf" : ' '
          {
            key: (idx + 1).to_s,
            label: "#{status} #{sender_name}: \"#{subject}\"",
            description: time_ago
          }
        end

        options << { key: 'n', label: 'New memo', description: 'Compose a new memo' }
        options << { key: 'q', label: 'Close', description: 'Close inbox' }

        memo_data = memos.map { |m| { id: m.id, sender: m.sender&.full_name, subject: m.subject } }

        prompt = if unread_count > 0
                   "Your Memos (#{memos.length} total, #{unread_count} unread):"
                 else
                   "Your Memos (#{memos.length} total):"
                 end

        create_quickmenu(
          character_instance,
          prompt,
          options,
          context: {
            command: 'mail',
            stage: 'select_memo',
            memos: memo_data
          }
        )
      end

      # ========================================
      # Read
      # ========================================

      def read_memo(number)
        if blank?(number)
          # Show inbox if no number
          return show_inbox
        end

        memos = Memo.inbox_for(character).all
        return error_result('You have no memos.') if memos.empty?

        memo_num = number.to_i
        if memo_num <= 0 || memo_num > memos.length
          return error_result("Invalid memo number. You have #{memos.length} memo(s).")
        end

        memo = memos[memo_num - 1]
        sender_name = memo.sender&.full_name || 'Unknown'
        was_unread = memo.unread?

        # Mark as read
        memo.mark_read!

        content = [
          "<h4>Memo ##{memo_num}</h4>",
          "From: #{sender_name}",
          "Subject: #{memo.subject}",
          "Date: #{memo.sent_at&.strftime('%Y-%m-%d %H:%M')}",
          '<hr>',
          memo.body
        ].join("\n")

        # Log first-read letters to the reader's story
        if was_unread && character_instance
          log_content = "#{character.full_name} reads a letter from #{sender_name}: \"#{memo.subject}\""
          IcActivityService.record_for(
            recipients: [character_instance], content: log_content,
            sender: character_instance, type: :mail
          )
        end

        success_result(
          content,
          type: :message,
          data: {
            action: 'read_memo',
            memo_id: memo.id,
            sender: sender_name,
            subject: memo.subject
          }
        )
      end

      # ========================================
      # Send
      # ========================================

      def send_memo(text)
        # No arguments - show composer form
        if blank?(text)
          return show_compose_form
        end

        # Parse recipient name
        target_name = text.strip.split(/\s+/).first

        recipient_result = resolve_mail_recipient(target_name, missing_error: 'Who do you want to send a memo to?')
        return recipient_result[:error] if recipient_result[:error]
        recipient = recipient_result[:recipient]

        # Always show form with recipient pre-filled
        show_compose_form(recipient_name: recipient.full_name)
      end

      def show_compose_form(recipient_name: nil)
        recent_contacts = ContactHistoryService.recent_contacts(character)

        fields = [
          {
            name: 'recipient',
            label: 'To',
            type: 'text',
            required: true,
            placeholder: 'Character name',
            value: recipient_name,
            autocomplete: recent_contacts.map { |c| c[:name] }
          },
          {
            name: 'subject',
            label: 'Subject',
            type: 'text',
            required: true,
            placeholder: 'Brief subject line'
          },
          {
            name: 'body',
            label: 'Message',
            type: 'textarea',
            required: true,
            placeholder: 'Write your message here...'
          }
        ]

        create_form(
          character_instance,
          'Compose Memo',
          fields,
          context: {
            command: 'mail'
          }
        )
      end

      def do_send_memo(recipient, subject, body)
        # For delayed messaging eras (medieval, gaslight), use MessengerService
        if defined?(EraService) && EraService.delayed_messaging?
          result = MessengerService.send_message(
            sender: character,
            recipient: recipient,
            subject: subject,
            body: body
          )

          if result[:success]
            return success_result(
              result[:message],
              type: :message,
              data: {
                action: 'send_memo',
                delivery_id: result.dig(:data, :delivery_id),
                recipient: recipient.full_name,
                subject: subject,
                scheduled_at: result.dig(:data, :scheduled_at),
                message_type: result.dig(:data, :message_type)
              }
            )
          else
            return error_result(result[:error])
          end
        end

        # Modern+ eras: instant delivery
        memo = Memo.create(
          sender_id: character.id,
          recipient_id: recipient.id,
          subject: subject,
          content: body
        )

        # Send Discord notification
        recipient_instance = recipient.character_instances_dataset.where(online: true).first
        NotificationService.notify_memo(recipient_instance, memo) if defined?(NotificationService) && recipient_instance

        success_result(
          "Memo sent to #{recipient.full_name}.\nSubject: #{subject}",
          type: :message,
          data: {
            action: 'send_memo',
            memo_id: memo.id,
            recipient: recipient.full_name,
            subject: subject
          }
        )
      end

      # ========================================
      # Delete
      # ========================================

      def delete_memo(target)
        memos = Memo.inbox_for(character).all

        return error_result('You have no memos to delete.') if memos.empty?

        # No argument - list memos for selection
        if blank?(target)
          return list_memos_for_deletion(memos)
        end

        # Handle 'all' option
        if target.downcase == 'all'
          count = memos.length
          Memo.where(recipient_id: character.id).delete
          return success_result(
            "Deleted all #{count} memo(s).",
            type: :message,
            data: { action: 'delete_all_memos', count: count }
          )
        end

        # Delete specific memo by number
        memo_num = target.to_i
        if memo_num <= 0 || memo_num > memos.length
          return error_result("Invalid memo number. You have #{memos.length} memo(s).")
        end

        memo = memos[memo_num - 1]
        subject = memo.subject
        sender_name = memo.sender&.full_name || 'Unknown'
        memo.destroy

        success_result(
          "Deleted memo ##{memo_num} from #{sender_name}: #{subject}",
          type: :message,
          data: {
            action: 'delete_memo',
            memo_number: memo_num,
            sender: sender_name,
            subject: subject
          }
        )
      end

      def list_memos_for_deletion(memos)
        lines = ["Which memo do you want to delete?\n"]

        memos.each_with_index do |memo, idx|
          num = idx + 1
          sender_name = memo.sender&.full_name || 'Unknown'
          subject = memo.subject || '(no subject)'
          read_status = memo.unread? ? '(UNREAD)' : ''

          lines << "  #{num}. From #{sender_name}: #{subject} #{read_status}"
        end

        lines << "\nUse 'mail delete <number>' or 'mail delete all'."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'list_memos_for_deletion',
            memo_count: memos.length
          }
        )
      end

      # ========================================
      # Helpers
      # ========================================

      def format_time_ago(time)
        return 'Unknown' unless time

        diff = Time.now - time
        if diff >= 604_800 # More than a week - show date
          time.strftime('%Y-%m-%d')
        else
          time_ago(time)
        end
      end

      def find_character(name)
        find_character_by_name_globally(name)
      end

      def resolve_mail_recipient(name, missing_error:)
        error = require_input(name, missing_error)
        return { error: error } if error

        recipient = find_character(name)
        return { error: error_result("No character found named '#{name}'.") } unless recipient
        return { error: error_result("You can't send a memo to yourself.") } if recipient.id == character.id

        { recipient: recipient }
      end

      def show_usage
        lines = [
          'Mail Commands:',
          '  mail              - View your inbox',
          '  mail list         - View your inbox',
          '  mail read <num>   - Read a specific memo',
          '  mail send <name>  - Compose a memo',
          '  mail delete <num> - Delete a memo',
          '  mail delete all   - Delete all memos'
        ]
        success_result(lines.join("\n"), type: :message)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Mail)
