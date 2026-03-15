# frozen_string_literal: true

require_relative '../../../../app/helpers/message_persistence_helper'

module Commands
  module Communication
    class Think < Commands::Base::Command
      include MessagePersistenceHelper

      command_name 'think'
      aliases 'hope', 'ponder', 'wonder', 'worry', 'wish', 'feel', 'remember'
      category :roleplaying
      help_text 'Express internal thoughts (visible to telepaths)'
      usage 'think <thought>'
      examples 'think I wonder what she meant by that', 'ponder the mysteries of the universe', 'worry about the future'

      requires_can_communicate_ic

      protected

      def perform_command(parsed_input)
        thought = parsed_input[:text]&.strip

        return error_result("What are you thinking?") if blank?(thought)

        # Validate for spam and abuse
        error = validate_message_content(thought, message_type: 'think')
        return error if error

        cmd_name = parsed_input[:command_word] || 'think'
        verb = determine_verb(cmd_name)
        formatted = format_thought(verb, thought)

        # Determine recipients: self + telepaths
        telepaths = character_instance.mind_readers.all
        recipients = [character_instance] + telepaths

        # Send to self
        send_to_character(character_instance, formatted)

        # Send to telepaths
        telepaths.each do |reader|
          telepathy_message = "[Telepathy] #{formatted}"
          send_to_character(reader, telepathy_message)
        end

        # Log for self + telepaths only
        log_roleplay(formatted, type: :think, recipients: recipients)

        success_result(
          "",
          type: :silent,
          data: {
            action: 'think',
            verb: verb,
            thought: thought
          }
        )
      end

      private

      def determine_verb(command_name)
        case command_name&.downcase
        when 'hope'     then 'hopes'
        when 'ponder'   then 'ponders'
        when 'wonder'   then 'wonders'
        when 'worry'    then 'worries'
        when 'wish'     then 'wishes'
        when 'feel'     then 'feels'
        when 'remember' then 'remembers'
        else                 'thinks'
        end
      end

      def format_thought(verb, thought)
        "<em>#{character.full_name}</em> #{verb}, \"#{thought}\""
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Communication::Think)
