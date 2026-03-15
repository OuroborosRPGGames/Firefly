# frozen_string_literal: true

module Commands
  module Communication
    # Unified bulletin board command.
    # Replaces: bulletin.rb, write_bulletin.rb, delete_bulletin.rb
    class BB < Commands::Base::Command
      command_name 'bb'
      aliases 'bulletin', 'bulletins', 'board'
      category :communication
      help_text 'View and manage the bulletin board'
      usage 'bb [subcommand] [arguments]'
      examples(
        'bb',
        'bb list',
        'bb post Looking for group!',
        'bb read 1',
        'bb delete'
      )

      protected

      def perform_command(parsed_input)
        args = parsed_input[:args] || []
        subcommand = args.first&.downcase
        sub_args = args[1..] || []

        case subcommand
        when nil, 'list', 'ls'
          list_bulletins
        when 'post', 'write', 'add'
          post_bulletin(sub_args.join(' '))
        when 'read', 'view'
          read_bulletin(sub_args.first)
        when 'delete', 'del', 'remove'
          delete_bulletin
        else
          # Check if they typed 'bb <message>' directly (no subcommand)
          if subcommand && !%w[list ls post write add read view delete del remove].include?(subcommand)
            # Treat entire input as a post
            post_bulletin(parsed_input[:text])
          else
            show_usage
          end
        end
      end

      private

      def list_bulletins
        bulletins = ::Bulletin.recent.all

        if bulletins.empty?
          return success_result(
            "The bulletin board is empty.\nUse 'bb post <message>' to post.",
            type: :message,
            data: { action: 'bulletin', count: 0 }
          )
        end

        lines = ["<h3>Bulletin Board</h3>"]

        bulletins.each_with_index do |bulletin, idx|
          age = bulletin.age_hours
          age_text = if age < 1
                       'just now'
                     elsif age < 24
                       "#{age}h ago"
                     else
                       "#{age / 24}d ago"
                     end

          lines << "<fieldset>"
          lines << "<legend>#{idx + 1}. #{bulletin.from_text} (#{age_text})</legend>"
          lines << bulletin.body
          lines << "</fieldset>\n"
        end

        lines << ""
        lines << "Commands: bb post <msg> | bb read <num> | bb delete"

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'bulletin',
            count: bulletins.length
          }
        )
      end

      def post_bulletin(text)
        return error_result("What do you want to post?\nUsage: bb post <message>") if blank?(text)

        body = text.strip

        max_len = GameConfig::Forms::MAX_LENGTHS[:bulletin_body]
        if body.length > max_len
          return error_result("Bulletin too long (max #{max_len} characters).")
        end

        # Delete any existing bulletins from this character
        ::Bulletin.delete_for_character(character)

        # Format the from_text
        from_text = character.full_name

        # Create new bulletin
        bulletin = ::Bulletin.create(
          character_id: character.id,
          from_text: from_text,
          body: body
        )

        # Broadcast to room
        preview = body.length > 100 ? "#{body[0, 97]}..." : body
        broadcast_to_room(
          "#{character.full_name} posts a bulletin: #{preview}",
          exclude_character: character_instance
        )

        success_result(
          "Bulletin posted!\n<fieldset><legend>#{from_text}</legend>#{body}</fieldset>",
          type: :message,
          data: {
            action: 'write_bulletin',
            bulletin_id: bulletin.id,
            body: body
          }
        )
      end

      def read_bulletin(number)
        return error_result("Usage: bb read <number>") if blank?(number)

        bulletins = ::Bulletin.recent.all
        idx = number.to_i - 1

        if idx < 0 || idx >= bulletins.length
          return error_result("Invalid bulletin number. Use 'bb' to see all bulletins.")
        end

        bulletin = bulletins[idx]
        age = bulletin.age_hours
        age_text = if age < 1
                     'just now'
                   elsif age < 24
                     "#{age}h ago"
                   else
                     "#{age / 24}d ago"
                   end

        lines = [
          "<fieldset>",
          "<legend>#{bulletin.from_text} (#{age_text})</legend>",
          bulletin.body,
          "</fieldset>"
        ]

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'read_bulletin',
            bulletin_id: bulletin.id
          }
        )
      end

      def delete_bulletin
        existing = ::Bulletin.by_character(character).all

        if existing.empty?
          return error_result("You don't have any bulletins to delete.")
        end

        count = existing.length
        ::Bulletin.delete_for_character(character)

        success_result(
          "Deleted #{count} bulletin(s).",
          type: :message,
          data: {
            action: 'delete_bulletin',
            count: count
          }
        )
      end

      def show_usage
        lines = [
          'Bulletin Board Commands:',
          '  bb              - View all bulletins',
          '  bb list         - View all bulletins',
          '  bb post <msg>   - Post a new bulletin',
          '  bb read <num>   - Read a specific bulletin',
          '  bb delete       - Delete your bulletin'
        ]
        success_result(lines.join("\n"), type: :message)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::BB)
