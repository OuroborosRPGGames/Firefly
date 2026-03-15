# frozen_string_literal: true

require_relative '../concerns/aesthete_concern'

module Commands
  module Clothing
    # Style command - Opens an editor to create hairstyles
    #
    # Hairstyles are stored as CharacterDefaultDescription with type 'hairstyle'
    # and are restricted to the 'scalp' body position.
    #
    # Usage:
    #   style me           - Open editor to style your own hair
    #   style Alice        - Open editor to style Alice's hair (requires permission)
    class Style < Commands::Base::Command
      include Commands::Clothing::AestheteConcern

      command_name 'style'
      aliases 'hairstyle', 'hair'
      category :clothing
      help_text "Style your own or someone else's hair using the description editor"
      usage 'style <target>'
      examples 'style me', 'style Alice'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip || ''

        # If no args, show usage
        if args.empty?
          return error_result("Whose hair do you want to style?\nUsage: style <target>\nExamples: style me, style Alice")
        end

        # Parse target
        target_name = args.split(/\s+/).first

        # Find target character
        target_char = resolve_aesthete_target(target_name)
        return target_char if target_char.is_a?(Hash) && !target_char[:success] # Error result

        # Check permission if targeting someone else
        unless has_aesthete_permission?(target_char)
          return error_result("You don't have permission to style #{target_char.full_name}'s hair.")
        end

        # Get scalp position only
        scalp_position = fetch_scalp_position
        unless scalp_position
          return error_result("Cannot find scalp body position in the system.")
        end

        # Build the form fields
        fields = build_form_fields(scalp_position)

        # Open the form
        title = if target_char.id == character.id
                  'Style Your Hair'
                else
                  "Style #{target_char.full_name}'s Hair"
                end

        create_form(
          character_instance,
          title,
          fields,
          context: {
            command: 'aesthete',
            aesthete_type: 'hairstyle',
            target_character_id: target_char.id,
            performer_id: character.id
          }
        )
      end

      private

      def fetch_scalp_position
        BodyPosition.first(label: 'scalp')
      end

      def build_form_fields(scalp_position)
        [
          {
            name: 'body_position_ids',
            label: 'Body Position',
            type: 'hidden',
            default: scalp_position.id.to_s,
            required: true
          },
          {
            name: 'content',
            label: 'Hairstyle Description',
            type: 'richtext',
            placeholder: 'Describe the hairstyle - length, color, style, accessories...',
            required: true,
            help_text: 'Use markdown for formatting, colors, etc.'
          },
          {
            name: 'image_url',
            label: 'Image (optional)',
            type: 'text',
            placeholder: 'https://example.com/hairstyle.jpg',
            required: false,
            help_text: 'URL to an image of the hairstyle'
          },
          {
            name: 'display_order',
            label: 'Display Order',
            type: 'number',
            default: 0,
            required: false,
            help_text: 'Lower numbers appear first when listing descriptions'
          }
        ]
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Clothing::Style)
