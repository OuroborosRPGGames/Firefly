# frozen_string_literal: true

require_relative '../concerns/aesthete_concern'

module Commands
  module Clothing
    # Tattoo command - Opens an editor to create permanent body art
    #
    # Tattoos are stored as CharacterDefaultDescription with type 'tattoo'
    # and can span multiple body positions.
    #
    # Usage:
    #   tattoo me           - Open editor to tattoo yourself
    #   tattoo Alice        - Open editor to tattoo Alice (requires permission)
    #   tattoo me back      - Open editor with back region preselected
    class Tattoo < Commands::Base::Command
      include Commands::Clothing::AestheteConcern

      command_name 'tattoo'
      category :clothing
      help_text 'Give yourself or someone else a tattoo using the description editor'
      usage 'tattoo <target> [body region]'
      examples 'tattoo me', 'tattoo me back', 'tattoo Alice arm'

      BODY_REGIONS = %w[head torso arms hands legs feet].freeze

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip || ''

        # If no args, show usage
        if args.empty?
          return error_result("Who do you want to tattoo?\nUsage: tattoo <target> [body region]\nExamples: tattoo me, tattoo Alice back")
        end

        # Parse target and optional region
        parts = args.split(/\s+/, 2)
        target_name = parts[0]
        region_hint = parts[1]&.downcase

        # Find target character
        target_char = resolve_aesthete_target(target_name)
        return target_char if target_char.is_a?(Hash) && !target_char[:success] # Error result

        # Check permission if targeting someone else
        unless has_aesthete_permission?(target_char)
          return error_result("You don't have permission to tattoo #{target_char.full_name}.")
        end

        # Get valid body positions
        body_positions = fetch_body_positions(region_hint)

        # Build the form fields
        fields = build_form_fields(body_positions, region_hint)

        # Open the form
        create_form(
          character_instance,
          "Tattoo #{target_char.id == character.id ? 'Yourself' : target_char.full_name}",
          fields,
          context: {
            command: 'aesthete',
            aesthete_type: 'tattoo',
            target_character_id: target_char.id,
            performer_id: character.id
          }
        )
      end

      private

      def fetch_body_positions(region_hint = nil)
        positions = BodyPosition.order(:region, :label).all

        # Group by region
        grouped = positions.group_by(&:region)

        # If region hint provided, filter or prioritize
        if region_hint && BODY_REGIONS.include?(region_hint)
          # Move the hinted region to front
          grouped = grouped.sort_by { |region, _| region == region_hint ? 0 : 1 }.to_h
        end

        grouped
      end

      def build_form_fields(body_positions, region_hint)
        # Build position options for select
        position_options = []

        body_positions.each do |region, positions|
          positions.each do |pos|
            label = pos.label.tr('_', ' ').split.map(&:capitalize).join(' ')
            position_options << {
              value: pos.id.to_s,
              label: "#{region.capitalize}: #{label}",
              group: region.capitalize
            }
          end
        end

        # Determine default position based on region hint
        default_position = nil
        if region_hint && body_positions[region_hint]&.any?
          default_position = body_positions[region_hint].first.id.to_s
        end

        [
          {
            name: 'body_position_ids',
            label: 'Body Position(s)',
            type: 'select',
            options: position_options,
            default: default_position,
            required: true,
            multiple: true, # Allow multi-select
            help_text: 'Select one or more body positions for the tattoo'
          },
          {
            name: 'content',
            label: 'Tattoo Description',
            type: 'richtext',
            placeholder: 'Describe the tattoo in detail - colors, style, imagery...',
            required: true,
            help_text: 'Use markdown for formatting, colors, etc.'
          },
          {
            name: 'image_url',
            label: 'Image (optional)',
            type: 'text',
            placeholder: 'https://example.com/tattoo.jpg',
            required: false,
            help_text: 'URL to an image of the tattoo'
          },
          {
            name: 'concealed_by_clothing',
            label: 'Hidden by clothing',
            type: 'checkbox',
            default: false,
            help_text: 'Check if this tattoo is normally covered by clothing'
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

Commands::Base::Registry.register(Commands::Clothing::Tattoo)
