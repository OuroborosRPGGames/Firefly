# frozen_string_literal: true

# Orchestrates TTS narration based on content type and user preferences.
# Routes content to appropriate voices (character voice for speech, narrator for everything else).
class TtsNarrationService
  class << self
    # Narrate content asynchronously in a background thread
    # @param character_instance [CharacterInstance] the listener
    # @param content [String] text content to narrate
    # @param type [Symbol] content type (:speech, :actions, :rooms, :system)
    # @param speaker [Character, nil] the speaking character (for :speech type)
    # @param broadcast [Boolean] whether to broadcast result to character via websocket
    # @param callback [Proc, nil] optional callback to receive result
    # @return [Hash] { request_id: 'uuid', queued: true } or { queued: false, reason: '...' }
    def narrate_async(character_instance, content, type:, speaker: nil, broadcast: true, callback: nil)
      # Validate preconditions synchronously
      unless character_instance
        return { queued: false, reason: 'No character instance' }
      end
      unless character_instance.tts_enabled?
        return { queued: false, reason: 'TTS not enabled for character' }
      end
      unless character_instance.should_narrate?(type)
        return { queued: false, reason: "Narration disabled for type: #{type}" }
      end
      unless TtsService.available?
        return { queued: false, reason: 'TTS service not available' }
      end

      request_id = SecureRandom.uuid

      # Run narration in background thread
      Thread.new do
        result = narrate(character_instance, content, type: type, speaker: speaker)

        if result && broadcast
          # Broadcast audio URL to character via websocket
          BroadcastService.to_character(
            character_instance,
            nil,
            type: :tts_audio,
            data: {
              request_id: request_id,
              audio_url: result[:audio_url],
              narration_type: result[:type]
            }
          )
        end

        # Call optional callback with result
        callback&.call(result)
      rescue StandardError => e
        warn "[TtsNarrationService] Async narration failed: #{e.message}"
        callback&.call(nil)
      end

      { request_id: request_id, queued: true }
    end

    # Narrate content for a character instance
    # @param character_instance [CharacterInstance] the listener
    # @param content [String] text content to narrate
    # @param type [Symbol] content type (:speech, :actions, :rooms, :system)
    # @param speaker [Character, nil] the speaking character (for :speech type)
    # @return [Hash, nil] { audio_url: '/audios/xyz.mp3' } or nil if TTS disabled/failed
    def narrate(character_instance, content, type:, speaker: nil)
      return nil unless character_instance
      return nil unless character_instance.tts_enabled?
      return nil unless character_instance.should_narrate?(type)
      return nil unless TtsService.available?

      case type
      when :speech
        narrate_speech(content, character_instance, speaker)
      when :actions, :rooms, :system
        narrate_with_narrator(content, character_instance)
      else
        nil
      end
    end

    # Narrate multiple pieces of content (e.g., room description + people present)
    # @param character_instance [CharacterInstance] the listener
    # @param items [Array<Hash>] array of { content: '...', type: :symbol, speaker: Character }
    # @return [Array<Hash>] array of narration results
    def narrate_batch(character_instance, items)
      return [] unless character_instance&.tts_enabled?
      return [] unless TtsService.available?

      items.filter_map do |item|
        narrate(
          character_instance,
          item[:content],
          type: item[:type],
          speaker: item[:speaker]
        )
      end
    end

    # Narrate room entry (description + occupants + time/weather if enabled)
    # @param character_instance [CharacterInstance] the listener
    # @param room_description [String] the room description
    # @param extra_text [String, nil] additional narration (occupants, weather)
    # @return [Hash, nil] narration result
    def narrate_room_entry(character_instance, room_description, extra_text: nil)
      return nil unless character_instance&.should_narrate?(:rooms)

      full_text = room_description.to_s
      full_text += " #{extra_text}" if extra_text && !extra_text.empty?

      narrate(character_instance, full_text, type: :rooms)
    end

    # Process emote/action content - may contain both narration and speech
    # Splits content into narrator parts and character speech parts
    # @param character_instance [CharacterInstance] the listener
    # @param content [String] the emote content
    # @param speaker [Character] the character performing the emote
    # @return [Array<Hash>] array of audio URLs for sequential playback
    def narrate_emote(character_instance, content, speaker:)
      return [] unless character_instance&.tts_enabled?
      return [] unless TtsService.available?

      # Check if user wants both actions and speech narrated
      narrate_actions = character_instance.should_narrate?(:actions)
      narrate_speech = character_instance.should_narrate?(:speech)

      return [] unless narrate_actions || narrate_speech

      # Split content into speech (quoted) and action (unquoted) parts
      parts = split_speech_and_action(content)

      results = []

      parts.each do |part|
        if part[:type] == :speech && narrate_speech
          # Use speaker's character voice for quoted speech
          result = narrate_speech(part[:text], character_instance, speaker)
          results << result if result
        elsif part[:type] == :action && narrate_actions
          # Use narrator voice for action descriptions
          result = narrate_with_narrator(part[:text], character_instance)
          results << result if result
        end
      end

      results
    end

    private

    # Narrate speech using the speaker's character voice
    def narrate_speech(content, listener, speaker)
      voice_settings = speaker&.voice_settings || {}

      result = TtsService.synthesize(
        content,
        voice_type: voice_settings[:voice_type] || TtsService::DEFAULT_VOICE,
        pitch: voice_settings[:voice_pitch] || 0.0,
        speed: voice_settings[:voice_speed] || 1.0
      )

      result[:success] ? { audio_url: result[:audio_url], type: :speech } : nil
    end

    # Narrate content using the listener's narrator voice
    def narrate_with_narrator(content, listener)
      user = listener.character&.user
      narrator_settings = user&.narrator_settings || {}

      result = TtsService.synthesize(
        content,
        voice_type: narrator_settings[:voice_type] || TtsService::DEFAULT_VOICE,
        pitch: narrator_settings[:voice_pitch] || 0.0,
        speed: narrator_settings[:voice_speed] || 1.0
      )

      result[:success] ? { audio_url: result[:audio_url], type: :narrator } : nil
    end

    # Split emote content into speech (quoted) and action (unquoted) parts
    # @param content [String] emote text
    # @return [Array<Hash>] array of { type: :speech/:action, text: '...' }
    def split_speech_and_action(content)
      return [] if content.nil? || content.empty?

      parts = []
      remaining = content.dup
      in_speech = false

      # Find speech patterns (text in quotes)
      segments = remaining.split('"')

      segments.each_with_index do |segment, index|
        next if segment.strip.empty?

        if index.even?
          # Even indices are outside quotes (action text)
          parts << { type: :action, text: segment.strip } unless segment.strip.empty?
        else
          # Odd indices are inside quotes (speech)
          parts << { type: :speech, text: segment.strip } unless segment.strip.empty?
        end
      end

      parts
    end
  end
end
