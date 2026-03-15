# frozen_string_literal: true

module Commands
  module System
    class Tickets < ::Commands::Base::Command
      command_name 'tickets'
      aliases 'mytickets', 'ticket', 'bug', 'typo', 'report', 'request', 'suggest', 'viewticket'
      category :system
      help_text 'Manage tickets - view, submit, and track bug reports, suggestions, and requests'
      usage 'tickets [list|new|view <id>|all]'
      examples 'tickets', 'tickets new', 'tickets view 42', 'bug', 'typo'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]&.strip || ''
        command_used = parsed_input[:command]&.downcase

        # Detect alias used - submission shortcuts
        shortcut_category = alias_to_category(command_used)
        if shortcut_category
          return show_ticket_form(shortcut_category)
        end

        # Handle 'ticket' alias without args as "submit new"
        if command_used == 'ticket' && text.empty?
          return show_ticket_form(nil)
        end

        # Handle 'viewticket' alias
        if command_used == 'viewticket' && !text.empty?
          return view_ticket(text.to_i)
        end

        # Strip command prefix
        text = text.sub(/^(tickets?|mytickets|viewticket)\s*/i, '').strip

        # No args - show tickets menu
        return show_tickets_menu if text.empty?

        # Parse action
        parts = text.split(/\s+/, 2)
        action = parts[0]&.downcase
        args = parts[1]&.strip

        case action
        when 'list', 'open'
          list_tickets(show_all: false)
        when 'all', 'history'
          list_tickets(show_all: true)
        when 'new', 'submit', 'create'
          category = (present?(args) && ::Ticket::CATEGORIES.include?(args.downcase)) ? args.downcase : nil
          show_ticket_form(category)
        when 'view', 'show', 'read'
          ticket_id = args&.to_i
          view_ticket(ticket_id)
        when 'bug', 'typo', 'request', 'suggestion', 'behaviour'
          # Direct category submission
          show_ticket_form(action)
        else
          # Try to interpret as ticket ID
          if action.match?(/^\d+$/)
            view_ticket(action.to_i)
          else
            error_result("Unknown action '#{action}'. Use: tickets list, tickets new, tickets view <id>")
          end
        end
      end

      def handle_form_response(form_data, _context)
        category = form_data['category']&.strip
        subject = form_data['subject']&.strip
        content = form_data['content']&.strip

        # Validate category
        unless ::Ticket::CATEGORIES.include?(category)
          return error_result('Invalid category.')
        end

        # Validate subject
        if subject.nil? || subject.empty?
          return error_result('Subject is required.')
        end

        max_subject = GameConfig::Forms::MAX_LENGTHS[:ticket_subject]
        if subject.length > max_subject
          return error_result("Subject too long (max #{max_subject} characters).")
        end

        # Validate content
        if content.nil? || content.empty?
          return error_result('Description is required.')
        end

        max_content = GameConfig::Forms::MAX_LENGTHS[:ticket_content]
        if content.length > max_content
          return error_result("Description too long (max #{max_content.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} characters).")
        end

        # Create ticket
        ticket = ::Ticket.create(
          user_id: character.user_id,
          category: category,
          subject: subject,
          content: content,
          status: 'open',
          room_id: location&.id,
          game_context: build_game_context
        )

        # Alert staff
        StaffAlertService.broadcast_to_staff(
          "[TICKET] New #{category.upcase} ticket ##{ticket.id} from #{character.user.username}: #{subject}"
        )

        success_result(
          "Ticket ##{ticket.id} submitted. Staff will review it shortly.\n" \
          "Use 'tickets' to view your open tickets.",
          type: :system,
          data: {
            action: 'create_ticket',
            ticket_id: ticket.id,
            category: category,
            subject: subject
          }
        )
      end

      private

      def alias_to_category(command_used)
        case command_used
        when 'bug' then 'bug'
        when 'typo' then 'typo'
        when 'report' then 'behaviour'
        when 'request' then 'request'
        when 'suggest' then 'suggestion'
        else nil
        end
      end

      def show_tickets_menu
        open_count = ::Ticket.where(user_id: character.user_id).status_open.count
        total_count = ::Ticket.where(user_id: character.user_id).count

        options = [
          { key: 'list', label: 'Open Tickets', description: "View #{open_count} open ticket#{open_count == 1 ? '' : 's'}" },
          { key: 'all', label: 'All Tickets', description: "View all #{total_count} ticket#{total_count == 1 ? '' : 's'}" },
          { key: 'new', label: 'Submit Ticket', description: 'Report a bug, typo, or make a request' }
        ]

        create_quickmenu(
          character_instance,
          'Ticket System',
          options,
          context: { command: 'tickets' }
        )
      end

      def list_tickets(show_all:)
        tickets = ::Ticket.where(user_id: character.user_id)
        tickets = tickets.status_open unless show_all
        tickets = tickets.order(Sequel.desc(:created_at)).limit(20).all

        if tickets.empty?
          msg = if show_all
                  "You have no tickets."
                else
                  "You have no open tickets.\nUse 'tickets all' to see resolved tickets."
                end
          return success_result(msg, type: :message)
        end

        # Build list with quickmenu to view individual tickets
        options = tickets.map do |t|
          status_icon = case t.status
                        when 'open' then '[OPEN]'
                        when 'resolved' then '[RESOLVED]'
                        when 'closed' then '[CLOSED]'
                        end
          {
            key: t.id.to_s,
            label: "##{t.id} #{status_icon}",
            description: "[#{t.category_display}] #{truncate(t.subject, 40)}"
          }
        end

        options << { key: 'new', label: 'Submit New', description: 'Create a new ticket' }
        options << { key: 'q', label: 'Close', description: 'Close menu' }

        ticket_data = tickets.map { |t| { id: t.id, subject: t.subject, status: t.status } }

        create_quickmenu(
          character_instance,
          show_all ? 'All Tickets' : 'Open Tickets',
          options,
          context: { command: 'tickets_list', tickets: ticket_data }
        )
      end

      def view_ticket(ticket_id)
        if ticket_id.nil? || ticket_id <= 0
          return error_result("Please specify a ticket ID. Usage: tickets view <id>")
        end

        ticket = ::Ticket.first(id: ticket_id, user_id: character.user_id)

        unless ticket
          return error_result("Ticket ##{ticket_id} not found or does not belong to you.")
        end

        lines = ["<h3>Ticket ##{ticket.id}</h3>"]
        lines << ''
        lines << "Category: #{ticket.category_display}"
        lines << "Status: #{ticket.status_display}"
        lines << "Subject: #{ticket.subject}"
        lines << "Submitted: #{ticket.created_at&.strftime('%Y-%m-%d %H:%M')}"
        lines << ''
        lines << 'Description:'
        lines << ticket.content
        lines << ''

        if ticket.resolved? || ticket.closed?
          lines << '<h5>Staff Response</h5>'
          lines << "Resolved by: #{ticket.resolved_by_user&.username || 'Staff'}"
          lines << "Resolved at: #{ticket.resolved_at&.strftime('%Y-%m-%d %H:%M')}"
          if ticket.resolution_notes && !ticket.resolution_notes.empty?
            lines << ''
            lines << ticket.resolution_notes
          end
        end

        success_result(
          lines.join("\n"),
          type: :system,
          data: ticket.to_admin_hash
        )
      end

      def show_ticket_form(preselected_category = nil)
        fields = [
          {
            name: 'category',
            label: 'Category',
            type: 'select',
            required: true,
            default: preselected_category,
            options: ::Ticket::CATEGORIES.map { |c| { value: c, label: c.capitalize } }
          },
          {
            name: 'subject',
            label: 'Subject',
            type: 'text',
            required: true,
            placeholder: 'Brief summary of the issue'
          },
          {
            name: 'content',
            label: 'Description',
            type: 'textarea',
            required: true,
            placeholder: 'Describe the issue in detail. Include steps to reproduce for bugs.'
          }
        ]

        create_form(
          character_instance,
          'Submit Ticket',
          fields,
          context: { command: 'tickets' }
        )
      end

      def build_game_context
        context = []
        context << "Room: #{location.name} (ID: #{location.id})" if location
        context << "Character: #{character.full_name}"
        context << "Time: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        context.join("\n")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::System::Tickets)
