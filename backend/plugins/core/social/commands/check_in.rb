# frozen_string_literal: true

module Commands
  module Social
    class CheckIn < Commands::Base::Command
      command_name 'check in'
      aliases 'checkin', 'locatability', 'where visibility', 'wherevis'
      category :social
      help_text 'Set your locatability (who can find you in the where list)'
      usage 'check in [yes|no|favorites]'
      examples 'check in', 'check in yes', 'check in no', 'check in favorites'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip&.downcase || ''

        # If no argument, show quickmenu
        if args.empty?
          return show_locatability_menu
        end

        # Handle direct setting
        case args
        when 'yes', 'on', 'visible', 'public'
          set_locatability('yes')
        when 'no', 'off', 'hidden', 'private'
          set_locatability('no')
        when 'favorites', 'favorite', 'friends'
          set_locatability('favorites')
        else
          error_result("Invalid option. Use: yes, no, or favorites")
        end
      end

      private

      def show_locatability_menu
        current = character_instance.locatability || 'yes'
        current_label = case current
                        when 'yes' then 'Anyone can find me'
                        when 'no' then 'Hidden from where'
                        when 'favorites' then 'Favorites only'
                        else current
                        end

        create_quickmenu(
          character_instance,
          "Set your locatability (who can find you in 'where'):\nCurrent: #{current_label}",
          [
            { key: 'yes', label: 'Yes - Anyone can find me', description: 'Appear in the where list for everyone' },
            { key: 'favorites', label: 'Favorites Only', description: 'Only players who marked you as favorite can see you' },
            { key: 'no', label: 'No - Hidden from where', description: 'Hidden from where list (except those who have always visibility)' }
          ],
          context: {
            command: 'locatability',
            instance_id: character_instance.id
          }
        )
      end

      def set_locatability(value)
        character_instance.update(locatability: value)

        label = case value
                when 'yes' then 'visible to anyone'
                when 'no' then 'hidden from where'
                when 'favorites' then 'visible only to favorites'
                else value
                end

        success_result(
          "Your locatability is now set to: #{label}",
          type: :system,
          data: {
            action: 'locatability_set',
            locatability: value
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Social::CheckIn)
