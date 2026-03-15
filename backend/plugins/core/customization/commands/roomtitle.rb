# frozen_string_literal: true

module Commands
  module Customization
    class Roomtitle < Commands::Base::Command
      command_name 'roomtitle'
      category :social
      help_text 'Set or clear the status text displayed after your name in rooms'
      usage 'roomtitle <text> | roomtitle clear'
      examples(
        'roomtitle looking thoughtful',
        'roomtitle leaning against the wall',
        'roomtitle clear'
      )

      MAX_ROOMTITLE_LENGTH = GameConfig::Forms::MAX_LENGTHS[:roomtitle]

      def perform_command(parsed_input)
        args = parsed_input[:text]

        if args.empty?
          return show_current
        end

        if args.downcase == 'clear'
          return clear_roomtitle
        end

        set_roomtitle(args)
      end

      private

      def show_current
        current = @character_instance.roomtitle
        if current && !current.empty?
          success_result(
            "Your current room title: #{current}",
            data: {
              action: 'view_roomtitle',
              roomtitle: current
            }
          )
        else
          success_result(
            "You don't have a room title set.\n" \
            "Use 'roomtitle <text>' to set one (e.g., roomtitle looking thoughtful).",
            data: {
              action: 'view_roomtitle',
              roomtitle: nil
            }
          )
        end
      end

      def set_roomtitle(value)
        if value.length > MAX_ROOMTITLE_LENGTH
          return error_result(
            "Room title too long (#{value.length} chars). Maximum is #{MAX_ROOMTITLE_LENGTH} characters."
          )
        end

        @character_instance.update(roomtitle: value)

        success_result(
          "Room title updated to: #{value}",
          data: {
            action: 'set_roomtitle',
            roomtitle: value
          }
        )
      end

      def clear_roomtitle
        @character_instance.update(roomtitle: nil)

        success_result(
          'Room title cleared.',
          data: {
            action: 'clear_roomtitle',
            roomtitle: nil
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Customization::Roomtitle)
