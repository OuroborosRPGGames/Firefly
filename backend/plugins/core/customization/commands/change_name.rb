# frozen_string_literal: true

module Commands
  module Customization
    class ChangeName < Commands::Base::Command
      command_name 'change name'
      category :social
      help_text 'Change your character nickname, forename, or surname'
      usage 'change name <nickname|forename|surname> <new value>'
      examples(
        'change name nickname Bobby',
        'change name forename Robert',
        'change name surname Smith'
      )

      VALID_NAME_TYPES = %w[nickname forename surname].freeze

      def perform_command(parsed_input)
        args = parsed_input[:text]

        if args.empty?
          return show_usage
        end

        parts = args.split(/\s+/, 2)
        name_type = parts[0]&.downcase
        new_value = parts[1]&.strip

        unless VALID_NAME_TYPES.include?(name_type)
          return error_result(
            "Invalid name type: #{name_type}\n" \
            "Valid types: #{VALID_NAME_TYPES.join(', ')}"
          )
        end

        if new_value.nil? || new_value.empty?
          return error_result("You must provide the new #{name_type}.")
        end

        case name_type
        when 'nickname'
          change_nickname(new_value)
        when 'forename'
          change_forename(new_value)
        when 'surname'
          change_surname(new_value)
        end
      end

      private

      # Validates name contains only letters, hyphens, apostrophes, and spaces
      def validate_name_characters(value, name_type)
        return nil if value.match?(/\A[a-zA-Z\s'\-]+\z/)

        error_result(
          "#{name_type.capitalize} contains invalid characters.\n" \
          "Only letters, spaces, hyphens, and apostrophes are allowed."
        )
      end

      def show_usage
        error_result(
          "Usage: change name <type> <new value>\n\n" \
          "Types:\n" \
          "  nickname - Your nickname (no cooldown)\n" \
          "  forename - Your first name (21-day cooldown)\n" \
          "  surname  - Your last name (21-day cooldown)\n\n" \
          "Examples:\n" \
          "  change name nickname Bobby\n" \
          "  change name forename Robert\n" \
          "  change name surname Smith"
        )
      end

      def change_nickname(value)
        character = @character_instance.character

        # Check uniqueness
        existing = Character.where(Sequel.ilike(:nickname, value)).exclude(id: character.id).first
        if existing
          return error_result("The nickname '#{value}' is already taken.")
        end

        # Validate length
        if value.length > 50
          return error_result("Nickname too long. Maximum is 50 characters.")
        end

        # Validate characters
        invalid = validate_name_characters(value, 'nickname')
        return invalid if invalid

        # Capitalize first letter
        value = value[0].upcase + value[1..-1] if value.length > 0 && value[0] != value[0].upcase

        begin
          character.update(nickname: value)
        rescue Sequel::ValidationFailed => e
          return error_result("Could not update nickname: #{e.message}")
        end

        success_result(
          "Nickname updated to: #{value}",
          data: {
            action: 'change_nickname',
            nickname: value
          }
        )
      end

      def change_forename(value)
        character = @character_instance.character

        # Check cooldown
        unless character.can_change_name?
          days = character.days_until_name_change
          return error_result(
            "You cannot change your forename yet.\n" \
            "You must wait #{days} more day(s) before changing your name again."
          )
        end

        # Check uniqueness of forename+surname combination
        existing = Character.where(
          Sequel.ilike(:forename, value)
        ).where(
          Sequel.ilike(:surname, character.surname || '')
        ).exclude(id: character.id).first

        if existing
          name_combo = character.surname ? "#{value} #{character.surname}" : value
          return error_result("The name '#{name_combo}' is already taken.")
        end

        # Validate length
        if value.length > 50
          return error_result("Forename too long. Maximum is 50 characters.")
        end

        # Validate characters
        invalid = validate_name_characters(value, 'forename')
        return invalid if invalid

        # Capitalize first letter
        value = value[0].upcase + value[1..-1] if value.length > 0 && value[0] != value[0].upcase

        old_name = character.full_name
        begin
          character.update(forename: value, last_name_change: Time.now)
        rescue Sequel::ValidationFailed => e
          return error_result("Could not change forename: #{e.message}")
        end
        new_name = character.full_name

        success_result(
          "Forename changed from #{old_name} to #{new_name}.\n" \
          'You cannot change your name again for 21 days.',
          data: {
            action: 'change_forename',
            old_name: old_name,
            new_name: new_name,
            forename: value
          }
        )
      end

      def change_surname(value)
        character = @character_instance.character

        # Check cooldown
        unless character.can_change_name?
          days = character.days_until_name_change
          return error_result(
            "You cannot change your surname yet.\n" \
            "You must wait #{days} more day(s) before changing your name again."
          )
        end

        # Check uniqueness of forename+surname combination
        existing = Character.where(
          Sequel.ilike(:forename, character.forename)
        ).where(
          Sequel.ilike(:surname, value)
        ).exclude(id: character.id).first

        if existing
          return error_result("The name '#{character.forename} #{value}' is already taken.")
        end

        # Validate length
        if value.length > 50
          return error_result("Surname too long. Maximum is 50 characters.")
        end

        # Validate characters
        invalid = validate_name_characters(value, 'surname')
        return invalid if invalid

        # Capitalize first letter
        value = value[0].upcase + value[1..-1] if value.length > 0 && value[0] != value[0].upcase

        old_name = character.full_name
        begin
          character.update(surname: value, last_name_change: Time.now)
        rescue Sequel::ValidationFailed => e
          return error_result("Could not change surname: #{e.message}")
        end
        new_name = character.full_name

        success_result(
          "Surname changed from #{old_name} to #{new_name}.\n" \
          'You cannot change your name again for 21 days.',
          data: {
            action: 'change_surname',
            old_name: old_name,
            new_name: new_name,
            surname: value
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Customization::ChangeName)
