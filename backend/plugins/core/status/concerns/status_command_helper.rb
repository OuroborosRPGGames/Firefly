# frozen_string_literal: true

module Commands
  module Status
    # Shared helpers for status toggle commands (afk, gtg, semiafk, quiet).
    module StatusCommandHelper
      private

      def broadcast_status_change(action_text)
        message = "#{character.full_name} #{action_text}"

        broadcast_to_room(message, exclude_character: character_instance, type: :status)
      end
    end
  end
end
