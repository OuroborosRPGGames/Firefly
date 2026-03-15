# frozen_string_literal: true

module Commands
  module Clothing
    class Pierce < Commands::Base::Command
      command_name 'pierce'
      category :clothing
      help_text 'Pierce a body position using a piercing-type jewelry item from your inventory'
      usage 'pierce <position> with <piercing item>'
      examples 'pierce my left ear with silver stud', 'pierce right eyebrow with gold ring'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Pierce what? Use: pierce <position> with <piercing item>") if blank?(text)

        # Parse: "my left ear with silver stud" or "left ear with gold ring"
        # Split on " with " to separate position from item
        parts = text.strip.split(/\s+with\s+/i, 2)

        if parts.length < 2 || blank?(parts[1])
          return error_result("Specify what piercing to use. Example: pierce my left ear with silver stud")
        end

        position = parts[0].sub(/^my\s+/i, '').strip
        item_name = parts[1].strip

        return error_result("Specify where to pierce. Example: pierce my left ear with silver stud") if blank?(position)

        # Find the piercing item in inventory (not worn)
        available_piercings = character_instance.objects.select do |item|
          item.piercing? && !item.worn?
        end

        if available_piercings.empty?
          return error_result("You don't have any piercing jewelry in your inventory. Get some first!")
        end

        # Match the item by name
        item = available_piercings.find do |p|
          p.name.downcase.include?(item_name.downcase)
        end

        unless item
          names = available_piercings.map(&:name).join(', ')
          return error_result("You don't have '#{item_name}' in your inventory. Available piercings: #{names}")
        end

        # Check if already pierced at this position
        already_pierced = character_instance.pierced_at?(position)

        # Add the piercing position if not already pierced there
        character_instance.add_piercing_position!(position) unless already_pierced

        # Wear the piercing at this position
        result = item.wear!(position: position)
        unless result == true
          return error_result(result)
        end

        action_msg = already_pierced ? "puts in" : "gets pierced at"

        broadcast_to_room(
          "#{character.full_name} #{action_msg} #{position} with #{item.name}.",
          exclude_character: character_instance
        )

        msg = if already_pierced
                "You put #{item.name} in your #{position} piercing."
              else
                "You pierce your #{position} with #{item.name}."
              end

        success_result(
          msg,
          type: :message,
          data: {
            action: 'pierce',
            item_id: item.id,
            item_name: item.name,
            position: position,
            new_piercing: !already_pierced
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Pierce)
