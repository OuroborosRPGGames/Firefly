# frozen_string_literal: true

module Commands
  module Clan
    class Clan < ::Commands::Base::Command
      command_name 'clan'
      aliases 'clans', 'guild', 'group'
      category :social
      help_text 'Manage your clan membership and activities'
      usage 'clan <subcommand> [arguments]'
      examples(
        'clan list',
        'clan create The Shadows',
        'clan create --secret The Hidden Order',
        'clan invite Alice',
        'clan kick Bob',
        'clan leave',
        'clan info',
        'clan roster',
        'clan memo',
        'clan handle ShadowMaster'
      )

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text] || ''
        parts = text.strip.split(/\s+/, 2)
        subcommand = parts[0]&.downcase
        rest = parts[1] || ''

        case subcommand
        when 'list', 'ls'
          list_clans
        when 'create', 'new'
          create_clan(rest)
        when 'invite', 'add'
          invite_member(rest)
        when 'kick', 'remove', 'boot'
          kick_member(rest)
        when 'leave', 'quit'
          leave_clan
        when 'info', 'show', 'view'
          show_clan_info(rest)
        when 'roster', 'members', 'who'
          show_roster(rest)
        when 'memo', 'mail'
          send_clan_memo(rest)
        when 'handle', 'alias', 'nick'
          set_handle(rest)
        when 'grant'
          grant_room_access
        when 'revoke'
          revoke_room_access
        when nil, ''
          show_help
        else
          show_help
        end
      end

      private

      # Get all clans this character belongs to
      def my_clans
        @my_clans ||= begin
          memberships = GroupMember.where(character_id: character.id, status: 'active')
                                   .eager(:group)
                                   .all
          memberships.map(&:group).compact.select { |g| g.group_type == 'clan' }
        end
      end

      # Get a single clan - returns the clan if only in one, nil if multiple or none
      def my_clan
        clans = my_clans
        return nil if clans.empty? || clans.length > 1

        clans.first
      end

      # Build quickmenu options for clan selection
      def clan_disambiguation_quickmenu(action:, **context)
        options = my_clans.each_with_index.map do |clan, idx|
          {
            key: (idx + 1).to_s,
            label: clan.name,
            description: clan.secret? ? '(Secret)' : "(#{clan.member_count} members)"
          }
        end
        options << { key: 'q', label: 'Cancel', description: 'Cancel this action' }

        {
          prompt: 'Which clan?',
          options: options,
          context: {
            command: 'clan',
            action: action,
            clan_ids: my_clans.map(&:id)
          }.merge(context)
        }
      end

      # Return a quickmenu result for clan disambiguation
      def clan_quickmenu_result(action:, **context)
        disambiguation_result(
          clan_disambiguation_quickmenu(action: action, **context),
          'Which clan?'
        )
      end

      def list_clans
        clans = ClanService.list_clans_for(character)

        if clans.empty?
          return success_result('No clans found. Create one with: clan create <name>')
        end

        output = ["<h4>Available Clans</h4>"]
        clans.each do |clan|
          is_member = clan.member?(character)
          status = is_member ? ' [Member]' : ''
          secret = clan.secret? ? ' (Secret)' : ''
          output << "  #{clan.display_name} - #{clan.member_count} members#{status}#{secret}"
        end

        success_result(output.join("\n"))
      end

      def create_clan(name)
        error = require_input(name, 'Usage: clan create <name>')
        return error if error

        # Check for secret flag
        secret = false
        if name.downcase.start_with?('--secret ')
          secret = true
          name = name.sub(/^--secret\s+/i, '')
        end

        result = ClanService.create_clan(
          character,
          name: name.strip,
          secret: secret,
          create_channel: true
        )

        if result[:success]
          clan = result[:clan]
          channel_msg = clan.channel ? "\nUse 'channel #{clan.name} <message>' to chat." : ''
          success_result(result[:message] + channel_msg)
        else
          error_result(result[:error])
        end
      end

      def invite_member(target_name)
        return error_result("You're not in a clan.") if my_clans.empty?

        error = require_input(target_name, 'Usage: clan invite <character>')
        return error if error

        # Parse optional handle with "as"
        parts = target_name.split(/\s+as\s+/i, 2)
        target_name_clean = parts[0].strip
        handle = parts[1]&.strip

        target = find_character_globally(target_name_clean)
        return error_result("No character found named '#{target_name_clean}'.") unless target

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(
            action: 'invite',
            target_id: target.id,
            handle: handle
          )
        end

        # Single clan - proceed directly
        result = ClanService.invite_member(my_clan, character, target, handle: handle)

        if result[:success]
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def kick_member(target_name)
        return error_result("You're not in a clan.") if my_clans.empty?

        error = require_input(target_name, 'Usage: clan kick <character>')
        return error if error

        target = find_character_globally(target_name.strip)
        return error_result("No character found named '#{target_name}'.") unless target

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(action: 'kick', target_id: target.id)
        end

        result = ClanService.kick_member(my_clan, character, target)

        if result[:success]
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def leave_clan
        return error_result("You're not in a clan.") if my_clans.empty?

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(action: 'leave')
        end

        result = ClanService.leave_clan(my_clan, character)

        if result[:success]
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def show_clan_info(name)
        name_blank = blank?(name)

        # If no name provided and in multiple clans, list them all
        if name_blank && my_clans.length > 1
          output = ["<h4>Your Clans</h4>"]
          my_clans.each do |c|
            membership = c.membership_for(character)
            channel_info = c.channel ? " - channel: #{c.name}" : ''
            output << "  #{c.display_name} [#{membership&.rank&.capitalize || 'Member'}]#{channel_info}"
          end
          output << "\nUse 'clan info <name>' to view a specific clan."
          output << "Use 'channel <clan name> <message>' to chat in a clan channel."
          return success_result(output.join("\n"))
        end

        clan = if name_blank
                 my_clan
               else
                 ClanService.find_clan_by_name_prefix(name.strip)
               end

        return error_result('Clan not found.') unless clan
        return error_result('That clan is secret.') if clan.secret? && !clan.member?(character)

        membership = clan.membership_for(character)

        output = [
          "<h4>#{clan.display_name}</h4>",
          "Type: #{clan.group_type.capitalize}",
          "Members: #{clan.member_count}",
          "Founded: #{clan.founded_at&.strftime('%Y-%m-%d') || 'Unknown'}"
        ]
        output << "Description: #{clan.description}" if clan.description && !clan.description.strip.empty?
        output << "Your Rank: #{membership.rank.capitalize}" if membership
        output << "Channel: #{clan.name}" if clan.channel
        output << 'Secret: Yes' if clan.secret?

        success_result(output.join("\n"))
      end

      def show_roster(name)
        name_blank = blank?(name)

        # If no name provided and in multiple clans, prompt
        if name_blank && my_clans.length > 1
          names = my_clans.map(&:name).join(', ')
          return error_result("You're in multiple clans (#{names}). Use 'clan roster <name>' to specify.")
        end

        clan = if name_blank
                 my_clan
               else
                 ClanService.find_clan_by_name_prefix(name.strip)
               end

        return error_result('Clan not found.') unless clan
        return error_result('That clan is secret.') if clan.secret? && !clan.member?(character)

        roster = clan.roster_for(character)

        output = ["<h4>#{clan.display_name} Roster</h4>"]
        roster.each do |member|
          rank_display = member[:is_leader] ? '[Leader]' : "[#{member[:rank].capitalize}]"
          output << "  #{member[:display_name]} #{rank_display}"
        end

        success_result(output.join("\n"))
      end

      def send_clan_memo(text)
        return error_result("You're not in a clan.") if my_clans.empty?

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(action: 'memo')
        end

        show_clan_memo_form(my_clan)
      end

      def show_clan_memo_form(clan)
        fields = [
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
            placeholder: 'Write your memo here...'
          }
        ]

        create_form(
          character_instance,
          "Clan Memo - #{clan.display_name}",
          fields,
          context: {
            command: 'clan',
            action: 'memo',
            clan_id: clan.id
          }
        )
      end

      def set_handle(new_handle)
        return error_result("You're not in a clan.") if my_clans.empty?

        handle_blank = blank?(new_handle)

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          if handle_blank
            # Show handles for all clans
            output = ["<h4>Your Clan Handles</h4>"]
            my_clans.each do |c|
              membership = c.membership_for(character)
              handle = membership&.handle || "(default: #{membership&.default_greek_handle || 'not set'})"
              output << "  #{c.name}: #{handle}"
            end
            output << "\nUse 'clan handle <name>' then select a clan to set your handle."
            return success_result(output.join("\n"))
          end

          return clan_quickmenu_result(action: 'handle', new_handle: new_handle.strip)
        end

        if handle_blank
          membership = my_clan.membership_for(character)
          current = membership&.handle || "(default: #{membership&.default_greek_handle || 'not set'})"
          return success_result("Your current handle in #{my_clan.name}: #{current}")
        end

        result = ClanService.set_handle(my_clan, character, new_handle.strip)

        if result[:success]
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def grant_room_access
        return error_result("You're not in a clan.") if my_clans.empty?

        # Must be in a room you own
        error = require_property_ownership
        return error if error

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(action: 'grant', room_id: location.id)
        end

        # Must be clan leader/officer
        membership = my_clan.membership_for(character)
        return error_result('Only officers can grant room access.') unless membership&.officer?

        my_clan.grant_room_access!(location, permanent: true)

        success_result("#{my_clan.display_name} members can now enter this room.")
      end

      def revoke_room_access
        return error_result("You're not in a clan.") if my_clans.empty?

        error = require_property_ownership
        return error if error

        # Show disambiguation if multiple clans
        if my_clans.length > 1
          return clan_quickmenu_result(action: 'revoke', room_id: location.id)
        end

        membership = my_clan.membership_for(character)
        return error_result('Only officers can revoke room access.') unless membership&.officer?

        my_clan.revoke_room_access!(location)

        success_result("#{my_clan.display_name} members can no longer enter this room.")
      end

      def handle_form_response(form_data, context)
        case context['action']
        when 'memo'
          handle_memo_form(form_data, context)
        else
          error_result('Unknown form action.')
        end
      end

      def handle_memo_form(form_data, context)
        clan_id = context['clan_id']
        clan = Group[clan_id]
        return error_result('Clan not found.') unless clan

        subject = form_data['subject']&.strip
        body = form_data['body']&.strip

        error = require_input(subject, 'Subject is required.')
        return error if error

        error = require_input(body, 'Message body is required.')
        return error if error

        result = ClanService.send_clan_memo(clan, character, subject: subject, body: body)

        if result[:success]
          success_result(result[:message])
        else
          error_result(result[:error])
        end
      end

      def show_help
        help = <<~HELP
          Clan Commands:
            clan list              - List all public clans and your clans
            clan create <name>     - Create a new clan (add --secret for secret clan)
            clan invite <player>   - Invite a player (leader/officer only)
            clan kick <player>     - Remove a player (leader/officer only)
            clan leave             - Leave a clan
            clan info [name]       - View clan details (lists your clans if in multiple)
            clan roster [name]     - View clan member list
            clan memo              - Send a memo to all clan members
            clan handle [name]     - Set your handle (alias) for secret clans
            clan grant             - Grant clan access to current room (owner only)
            clan revoke            - Revoke clan access to current room (owner only)

          Chat: Use 'channel <clan name> <message>' to chat in clan channels.
          Example: channel The Shadows Hello everyone!
        HELP

        success_result(help.strip)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clan::Clan)
