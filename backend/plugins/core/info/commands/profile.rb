# frozen_string_literal: true

module Commands
  module Info
    class Profile < Commands::Base::Command
      command_name 'profile'
      aliases 'view profile'
      category :info
      output_category :info
      help_text 'View a character profile'
      usage 'profile [character]'
      examples 'profile', 'profile Alice'

      protected

      def perform_command(parsed_input)
        target_name = parsed_input[:text]&.strip

        if blank?(target_name)
          # View own profile
          display_profile(character_instance)
        else
          # View another's profile (uses CharacterLookupHelper)
          target = find_character_room_then_global(
            target_name,
            room: location,
            reality_id: character_instance.reality_id,
            exclude_instance_id: character_instance.id
          )
          unless target
            return error_result("No character named '#{target_name}' found.")
          end
          display_profile(target)
        end
      end

      private

      def display_profile(target_instance)
        target_char = target_instance.character
        is_self = (target_instance.id == character_instance.id)

        name_display = is_self ? "Your Profile" : "#{target_char.full_name}'s Profile"
        lines = ["<h3>#{name_display}</h3>"]
        lines << ""

        # Identity section
        lines << "Name: #{target_char.full_name}"

        # Race, Class, Gender, Age on one line if present
        identity_parts = []
        identity_parts << "Race: #{target_char.race}" if target_char.race && !target_char.race.empty?
        identity_parts << "Class: #{target_char.character_class}" if target_char.character_class && !target_char.character_class.empty?
        identity_parts << "Gender: #{target_char.gender}" if target_char.gender && !target_char.gender.empty?
        identity_parts << "Age: #{target_char.age}" if target_char.age

        lines << identity_parts.join(' | ') if identity_parts.any?

        # Physical
        physical_parts = []
        if target_char.height_display
          physical_parts << "Height: #{target_char.height_display}"
        end
        if target_char.respond_to?(:ethnicity) && target_char.ethnicity && !target_char.ethnicity.empty?
          physical_parts << "Ethnicity: #{target_char.ethnicity}"
        end

        lines << physical_parts.join(' | ') if physical_parts.any?

        lines << ""

        # Profile picture
        if target_char.picture_url && !target_char.picture_url.empty?
          lines << "Profile Picture: #{target_char.picture_url}"
          lines << ""
        end

        # Short description
        if target_char.short_desc && !target_char.short_desc.empty?
          lines << "Short Description: #{target_char.short_desc}"
          lines << ""
        end

        # Current status
        lines << '<h5>Current Status</h5>'

        if target_instance.online
          room_name = target_instance.current_room&.name || 'Unknown'
          stance = target_instance.current_stance

          location_text = "Currently: #{stance}"
          if target_instance.current_place
            prep = target_instance.current_place.default_sit_action || 'at'
            location_text += " #{prep} #{target_instance.current_place.name}"
          end
          location_text += " in #{room_name}"
          lines << location_text

          lines << "Status: Online"
        else
          lines << "Status: Offline"
        end

        lines << "Level: #{target_instance.level}"

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            action: 'profile',
            target_id: target_instance.id,
            target_name: target_char.full_name,
            is_self: is_self
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Info::Profile)
