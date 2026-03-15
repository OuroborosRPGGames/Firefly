# frozen_string_literal: true

# Personalizes messages for individual viewers based on their knowledge,
# sensory state, and other factors.
#
# This service provides an extensible pipeline for transforming messages
# before they're delivered to each recipient. Transformations include:
# - Name substitution (characters appear as known names or descriptions)
# - Sensory filtering (blindfolded characters can't see visual details)
# - Future: deafness, language barriers, etc.
#
# Usage:
#   # Basic personalization
#   personalized = MessagePersonalizationService.personalize(
#     message: "Bob Smith waves at everyone.",
#     viewer: viewer_instance,
#     room_characters: room_chars
#   )
#
#   # With message type for sensory filtering
#   personalized = MessagePersonalizationService.personalize(
#     message: "Bob Smith waves at everyone.",
#     viewer: viewer_instance,
#     message_type: :visual  # Will be filtered for blindfolded viewers
#   )
#
class MessagePersonalizationService
  class << self
    # Personalize a message for a specific viewer
    #
    # @param message [String] The original message
    # @param viewer [CharacterInstance] The character who will see this message
    # @param room_characters [Array<CharacterInstance>, nil] Characters in room for name substitution
    # @param message_type [Symbol] Type of message for sensory filtering (:visual, :auditory, :mixed)
    # @param options [Hash] Additional options for specific transformers
    # @return [String, nil] The personalized message, or nil if message was nil
    def personalize(message:, viewer:, room_characters: nil, message_type: :mixed, **options)
      return message if message.nil? || message.empty?
      return message unless viewer

      result = message.dup

      # Run through transformation pipeline
      transformers.each do |transformer|
        result = transformer.call(
          message: result,
          viewer: viewer,
          room_characters: room_characters,
          message_type: message_type,
          **options
        )
      end

      result
    end

    # Register a custom transformer to the pipeline
    # Transformers are called in order of registration
    #
    # @param name [Symbol] Unique name for this transformer
    # @param transformer [Proc, #call] Object responding to call(message:, viewer:, **options)
    def register_transformer(name, transformer = nil, &block)
      transformer ||= block
      raise ArgumentError, "Transformer must respond to #call" unless transformer.respond_to?(:call)

      @custom_transformers ||= {}
      @custom_transformers[name] = transformer
    end

    # Remove a custom transformer
    def unregister_transformer(name)
      @custom_transformers&.delete(name)
    end

    private

    # The transformation pipeline - order matters!
    def transformers
      [
        method(:substitute_names),
        method(:apply_sensory_filters),
        *(@custom_transformers&.values || [])
      ]
    end

    # ========================================
    # Built-in Transformers
    # ========================================

    # Substitute character names based on viewer's knowledge
    def substitute_names(message:, viewer:, room_characters: nil, **)
      return message if message.nil? || message.empty?

      # Get room characters if not provided
      room_characters ||= fetch_room_characters(viewer)
      return message if room_characters.nil? || room_characters.empty?

      # Split message into speech (quoted) and action (unquoted) segments
      # Only substitute names in action segments — speech is verbatim
      segments = EmoteParserService.parse(message)

      sorted_chars = room_characters
                     .select { |ci| ci.character }
                     .sort_by { |ci| -(ci.character.name_variants.first&.length || 0) }

      segments.map! do |seg|
        if seg[:type] == :speech
          seg
        else
          seg[:text] = substitute_in_text(seg[:text], sorted_chars, viewer)
          seg
        end
      end

      # Reassemble: wrap speech segments in their original quote characters
      segments.map do |s|
        if s[:type] == :speech
          q = s[:quote_char] || '"'
          "#{q}#{s[:text]}#{q}"
        else
          s[:text]
        end
      end.join
    end

    # Substitute character names in a text segment.
    # Builds a globally-sorted list of all variants from all characters,
    # processing longest variants first to avoid partial matches
    # (e.g., "Smith" matching inside "John Smith Jr").
    def substitute_in_text(text, sorted_chars, viewer)
      # Normalize smart/curly quotes to straight quotes before matching.
      # LLMs and rich text editors often convert ' to \u2018/\u2019,
      # which breaks matching against name_variants (e.g., "Linis 'Lin' Dao").
      substituted = normalize_quotes(text)

      # Build all (variant, char_instance, display_name, is_viewer) entries
      all_entries = []
      sorted_chars.each do |char_instance|
        display_name = char_instance.character.display_name_for(viewer, room_characters: sorted_chars)
        is_viewer = (char_instance.id == viewer.id)

        char_instance.character.name_variants.each do |variant|
          next if variant.nil? || variant.empty?

          all_entries << {
            variant: variant,
            char_id: char_instance.id,
            display_name: display_name,
            is_viewer: is_viewer
          }
        end
      end

      # Sort ALL variants by length (longest first) to prevent partial matches
      all_entries.sort_by! { |e| -e[:variant].length }

      # Track which characters have already been matched
      matched_char_ids = {}

      all_entries.each do |entry|
        next if matched_char_ids[entry[:char_id]]

        pattern = /(?<=\A|\W)(#{Regexp.escape(entry[:variant])})(?=\W|\z)/i
        next unless substituted.match?(pattern)

        substituted = substituted.gsub(pattern) do
          pre = $~.pre_match
          # Skip if already inside <strong> tags (from prior personalization during sync/reconnect)
          next $& if pre.match?(/<strong>\z/)

          name = if pre.empty? || pre.match?(/[.!?]\s*\z/)
                   capitalize_first(entry[:display_name])
                 else
                   entry[:display_name]
                 end
          if entry[:is_viewer]
            pov = viewer.character.point_of_view
            if pov == 'Second'
              (pre.empty? || pre.match?(/[.!?]\s*\z/)) ? 'You' : 'you'
            else
              "<strong>#{name}</strong>"
            end
          else
            name
          end
        end
        matched_char_ids[entry[:char_id]] = true
      end
      substituted
    end

    # Apply sensory filters based on viewer's state
    def apply_sensory_filters(message:, viewer:, message_type: :mixed, **)
      return message if message.nil? || message.empty?
      return message unless viewer.respond_to?(:blindfolded?)

      case message_type
      when :visual
        # Blindfolded characters can't see visual-only messages
        if viewer.blindfolded?
          return "[You can't see what's happening.]"
        end
      when :auditory
        # Future: deaf characters can't hear auditory-only messages
        # if viewer.deaf?
        #   return "[You can't hear what's being said.]"
        # end
      when :mixed
        # Mixed messages (most common) - no filtering, but could add partial filtering
        # e.g., "You hear someone moving around." for blindfolded viewers
      end

      message
    end

    # Normalize smart/curly quotes to straight ASCII quotes
    def normalize_quotes(text)
      return text if text.nil?

      text.gsub(/[\u2018\u2019\u201A]/, "'")
          .gsub(/[\u201C\u201D\u201E]/, '"')
    end

    # Capitalize the first letter of a string without changing the rest
    def capitalize_first(str)
      return str if str.nil? || str.empty?

      str[0].upcase + str[1..]
    end

    # Fetch room characters for name substitution
    def fetch_room_characters(viewer)
      return [] unless viewer&.current_room_id

      CharacterInstance
        .where(current_room_id: viewer.current_room_id, online: true)
        .eager(:character)
        .all
    end
  end
end
