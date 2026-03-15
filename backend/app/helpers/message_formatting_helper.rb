# frozen_string_literal: true

# Helper module for formatting narrative messages in communication commands.
# Consolidates duplicated formatting patterns across say, whisper, say_to, etc.
#
# @example Usage in a command
#   include MessageFormattingHelper
#
#   def format_message(name, text, adverb)
#     format_narrative_message(
#       character_name: name,
#       text: text,
#       verb: 'says',
#       adverb: adverb
#     )
#   end
#
module MessageFormattingHelper
  # Format a narrative message with random variant selection.
  # Randomly chooses between two styles:
  # - Format A: "Name [adverb?] verb [to Target], 'message'"
  # - Format B: "'message' Name [adverb?] verb [to Target]."
  #
  # @param character_name [String] speaker's name
  # @param text [String] the message content
  # @param verb [String] action verb (says, whispers, tells, yells)
  # @param adverb [String, nil] optional adverb (quietly, loudly)
  # @param target_name [String, nil] optional target name
  # @param quote_char [String] quote character (' or ")
  # @param adverb_before_verb [Boolean] place adverb before verb (whispers) vs after (says)
  # @param speech_color [String, nil] hex color for the speech text (e.g., '#FF5733')
  # @return [String] formatted narrative message
  def format_narrative_message(character_name:, text:, verb:, adverb: nil,
                                target_name: nil, quote_char: "'",
                                adverb_before_verb: false, speech_color: nil)
    text = text.to_s
    adverb_str = adverb && !adverb.to_s.empty? ? " #{adverb.downcase}" : ''
    target_str = target_name ? " to #{target_name}" : ''

    # Build the verb phrase based on adverb position
    verb_phrase = if adverb_before_verb && !adverb_str.empty?
                    "#{adverb_str.strip} #{verb}"
                  elsif !adverb_str.empty?
                    "#{verb}#{adverb_str}"
                  else
                    verb
                  end

    # Apply speech color to the quoted text if provided
    display_text = apply_speech_color_to_text(text, speech_color)

    if rand(2) == 0
      # Format A: "Name [verb phrase] [to Target], 'message'"
      "#{character_name} #{verb_phrase}#{target_str}, #{quote_char}#{display_text}#{quote_char}"
    else
      # Format B: "'message' Name [verb phrase] [to Target]."
      "#{quote_char}#{display_text}#{quote_char} #{character_name} #{verb_phrase}#{target_str}."
    end
  end

  # Format an obscured message (for observers who shouldn't see content).
  # Used for private messages where observers see something like:
  # "Bob quietly says something privately to Alice."
  #
  # @param character_name [String] speaker's name
  # @param verb [String] action verb (says, whispers, tells)
  # @param target_name [String] target's name
  # @param adverb [String, nil] optional adverb
  # @return [String] formatted obscured message
  def format_obscured_message(character_name:, verb:, target_name:, adverb: nil)
    adverb_str = adverb && !adverb.to_s.empty? ? " #{adverb.downcase}" : ''
    "#{character_name}#{adverb_str} #{verb} something to #{target_name}."
  end

  # Remove trailing punctuation for embedding text in quotes.
  # Used when wrapping message in quotes to avoid double punctuation.
  #
  # @example
  #   comma_punctuate("Hello!") # => "Hello"
  #   comma_punctuate("Hi there.") # => "Hi there"
  #
  # @param text [String] the message text
  # @return [String] text with trailing punctuation removed
  def comma_punctuate(text)
    text.to_s.strip.sub(/[.!?]$/, '')
  end

  # Wrap text in a speech color span if a valid color is provided.
  # Can be called as an instance method (when module is included) or as
  # MessageFormattingHelper.apply_speech_color_to_text(text, color).
  #
  # @param text [String] the speech text
  # @param color [String, nil] hex color (e.g., '#FF5733')
  # @return [String] the text, optionally wrapped in a color span
  def apply_speech_color_to_text(text, color)
    return text if StringHelper.blank?(color)

    color = color.to_s.strip
    return text unless color.match?(/\A#[0-9A-Fa-f]{3,6}\z/)

    "<span style=\"color:#{color}\">#{text}</span>"
  end
  module_function :apply_speech_color_to_text
end
