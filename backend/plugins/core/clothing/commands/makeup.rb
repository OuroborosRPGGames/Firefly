# frozen_string_literal: true

require_relative '../concerns/aesthete_concern'

module Commands
  module Clothing
    # Makeup command - Opens an editor to apply makeup
    #
    # Makeup descriptions are stored as CharacterDefaultDescription with type 'makeup'
    # and are restricted to face positions (forehead, eyes, nose, cheeks, chin, mouth).
    #
    # Usage:
    #   makeup me           - Open editor to apply makeup to yourself
    #   makeup Alice        - Open editor to apply makeup to Alice (requires permission)
    #   makeup me eyes      - Open editor with eyes preselected
    class Makeup < Commands::Base::Command
      include Commands::Clothing::AestheteConcern

      command_name 'makeup'
      aliases 'cosmetics', 'makeover'
      category :clothing
      help_text 'Apply makeup to yourself or someone else using the description editor'
      usage 'makeup <target> [face area]'
      examples 'makeup me', 'makeup me eyes', 'makeup Alice lips'

      # Face areas map to MAKEUP_POSITIONS
      FACE_AREAS = {
        'forehead' => 'forehead',
        'eyes' => 'eyes',
        'eye' => 'eyes',
        'nose' => 'nose',
        'cheeks' => 'cheeks',
        'cheek' => 'cheeks',
        'chin' => 'chin',
        'mouth' => 'mouth',
        'lips' => 'mouth',
        'lip' => 'mouth'
      }.freeze

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip || ''

        # If no args, show usage
        if args.empty?
          return error_result("Who do you want to apply makeup to?\nUsage: makeup <target> [face area]\nExamples: makeup me, makeup me eyes, makeup Alice")
        end

        # Parse target and optional face area
        parts = args.split(/\s+/, 2)
        target_name = parts[0]
        area_hint = parts[1]&.downcase

        # Find target character
        target_char = resolve_aesthete_target(target_name)
        return target_char if target_char.is_a?(Hash) && !target_char[:success] # Error result

        # Check permission if targeting someone else
        unless has_aesthete_permission?(target_char)
          return error_result("You don't have permission to apply makeup to #{target_char.full_name}.")
        end

        # Get face positions only (makeup-valid positions)
        face_positions = fetch_face_positions
        if face_positions.empty?
          return error_result("Cannot find face body positions in the system.")
        end

        # Build the form fields
        fields = build_form_fields(face_positions, area_hint)

        # Open the form
        create_form(
          character_instance,
          "Apply Makeup to #{target_char.id == character.id ? 'Yourself' : target_char.full_name}",
          fields,
          context: {
            command: 'aesthete',
            aesthete_type: 'makeup',
            target_character_id: target_char.id,
            performer_id: character.id
          }
        )
      end

      private

      def fetch_face_positions
        # Only get the positions valid for makeup
        makeup_labels = CharacterDefaultDescription::MAKEUP_POSITIONS
        BodyPosition.where(label: makeup_labels).order(:id).all
      end

      def build_form_fields(face_positions, area_hint)
        # Build position options for select
        position_options = face_positions.map do |pos|
          label = pos.label.tr('_', ' ').split.map(&:capitalize).join(' ')
          {
            value: pos.id.to_s,
            label: label
          }
        end

        # Determine default position based on area hint
        default_position = nil
        if area_hint
          normalized_area = FACE_AREAS[area_hint]
          if normalized_area
            matching = face_positions.find { |p| p.label == normalized_area }
            default_position = matching&.id&.to_s
          end
        end

        [
          {
            name: 'body_position_ids',
            label: 'Face Area(s)',
            type: 'select',
            options: position_options,
            default: default_position,
            required: true,
            multiple: true, # Allow multi-select for makeup that spans areas
            help_text: 'Select one or more face areas for the makeup'
          },
          {
            name: 'content',
            label: 'Makeup Description',
            type: 'richtext',
            placeholder: 'Describe the makeup - colors, style, effects...',
            required: true,
            help_text: 'Use markdown for formatting, colors, etc.'
          },
          {
            name: 'image_url',
            label: 'Image (optional)',
            type: 'text',
            placeholder: 'https://example.com/makeup.jpg',
            required: false,
            help_text: 'URL to an image of the makeup look'
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

Commands::Base::Registry.register(Commands::Clothing::Makeup)
