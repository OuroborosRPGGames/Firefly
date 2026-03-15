# frozen_string_literal: true

# Manages TTS audio queue for accessibility mode.
# Generates and queues audio content for sequential playback.
#
# Only queues audio when accessibility mode is enabled.
# Supports mixing narrator and character voices.
#
# @example
#   service = TtsQueueService.new(character_instance)
#   service.queue_narration("You enter the room.", type: :room)
#   service.queue_speech("Hello!", speaker: other_character)
#
class TtsQueueService
  attr_reader :character_instance

  # Content type to voice type mapping
  CONTENT_VOICES = {
    narrator: :narrator,   # Uses user's narrator voice
    room: :narrator,       # Room descriptions use narrator
    system: :narrator,     # System messages use narrator
    combat: :narrator,     # Combat narrative uses narrator
    action: :narrator,     # Emotes/actions use narrator
    speech: :character     # Character speech uses character voice
  }.freeze

  def initialize(character_instance)
    @character_instance = character_instance
  end

  # Queue narration content (room descriptions, actions, system messages)
  # @param content [String] text content to narrate
  # @param type [Symbol] content type (:narrator, :room, :system, :combat, :action)
  # @return [Hash, nil] queue item info or nil if not queued
  def queue_narration(content, type: :narrator)
    return nil unless should_queue?
    return nil if content.nil? || content.strip.empty?

    # Get narrator voice settings from user
    voice_settings = narrator_voice_settings

    queue_item(
      content: content,
      type: type,
      voice_type: voice_settings[:voice_type],
      voice_pitch: voice_settings[:voice_pitch],
      voice_speed: voice_settings[:voice_speed]
    )
  end

  # Queue character speech (say, whisper, yell)
  # @param content [String] speech content
  # @param speaker [Character, CharacterInstance, nil] speaking character
  # @param speech_type [Symbol] :say, :whisper, :yell, :tell
  # @return [Hash, nil] queue item info or nil if not queued
  def queue_speech(content, speaker: nil, speech_type: :say)
    return nil unless should_queue?
    return nil if content.nil? || content.strip.empty?

    # Get speaker's voice settings
    voice_settings = speaker_voice_settings(speaker)

    # Prefix with speaker name for clarity
    speaker_name = extract_speaker_name(speaker)
    full_content = speaker_name ? "#{speaker_name} says: #{content}" : content

    queue_item(
      content: full_content,
      type: :speech,
      voice_type: voice_settings[:voice_type],
      voice_pitch: voice_settings[:voice_pitch],
      voice_speed: voice_settings[:voice_speed]
    )
  end

  # Get pending audio items for the client
  # @param from_position [Integer, nil] starting sequence number
  # @param limit [Integer] max items to return
  # @return [Array<Hash>] pending audio items
  def pending_items(from_position: nil, limit: 20)
    from_pos = from_position || character_instance.tts_queue_position || 0

    AudioQueueItem.pending_for(
      character_instance.id,
      from_position: from_pos,
      limit: limit
    ).map(&:to_api_hash)
  end

  # Mark items as played up to a sequence number
  # @param sequence_number [Integer]
  # @return [Integer] number of items marked
  def mark_played_up_to(sequence_number)
    count = character_instance.audio_queue_items_dataset
                              .where { sequence_number <= sequence_number }
                              .where(played: false)
                              .update(played: true, played_at: Time.now)

    character_instance.update(tts_queue_position: sequence_number)
    count
  end

  # Clear all pending items
  # @return [Integer] number of items cleared
  def clear_queue
    count = character_instance.audio_queue_items_dataset
                              .where(played: false)
                              .delete

    character_instance.skip_to_latest!
    count
  end

  # Get queue statistics
  # @return [Hash]
  def queue_stats
    total = character_instance.audio_queue_items_dataset.count
    pending = character_instance.audio_queue_items_dataset.where(played: false).count
    played = total - pending

    {
      total: total,
      pending: pending,
      played: played,
      paused: character_instance.tts_paused?,
      position: character_instance.tts_queue_position || 0
    }
  end

  # Class methods for static use
  class << self
    # Queue content for a character instance (convenience method)
    # @param character_instance [CharacterInstance]
    # @param content [String]
    # @param type [Symbol]
    # @param speaker [Character, CharacterInstance, nil]
    # @return [Hash, nil]
    def queue_for(character_instance, content, type:, speaker: nil)
      service = new(character_instance)

      if type == :speech && speaker
        service.queue_speech(content, speaker: speaker)
      else
        service.queue_narration(content, type: type)
      end
    end

    # Check if a character instance should receive TTS content
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def should_queue_for?(character_instance)
      return false unless character_instance

      # Only queue for accessibility mode users with TTS enabled
      character_instance.accessibility_mode? &&
        character_instance.tts_enabled? &&
        !character_instance.tts_paused?
    end
  end

  private

  # Check if we should queue audio for this character
  # @return [Boolean]
  def should_queue?
    return false unless character_instance

    # Only queue for accessibility mode users with TTS enabled
    character_instance.accessibility_mode? &&
      character_instance.tts_enabled? &&
      !character_instance.tts_paused?
  end

  # Queue a single audio item
  # @param content [String] text content
  # @param type [Symbol] content type
  # @param voice_type [String] voice name
  # @param voice_pitch [Float] pitch adjustment
  # @param voice_speed [Float] speaking rate
  # @return [Hash, nil] queue item info or nil if synthesis failed
  def queue_item(content:, type:, voice_type:, voice_pitch:, voice_speed:)
    # Synthesize audio
    result = TtsService.synthesize(
      content,
      voice_type: voice_type,
      pitch: voice_pitch,
      speed: voice_speed
    )

    unless result[:success]
      warn "[TtsQueueService] Synthesis failed: #{result[:error]}"
      return nil
    end

    # Create queue item
    sequence = AudioQueueItem.next_sequence_for(character_instance.id)

    item = AudioQueueItem.create(
      character_instance_id: character_instance.id,
      audio_url: result[:audio_url],
      content_type: type.to_s,
      voice_type: voice_type,
      original_text: content[0, 1000],
      sequence_number: sequence,
      duration_seconds: estimate_duration(content, voice_speed),
      queued_at: Time.now,
      expires_at: Time.now + (AudioQueueItem::QUEUE_EXPIRY_MINUTES * 60)
    )

    item.to_api_hash
  end

  # Get narrator voice settings from user
  # @return [Hash]
  def narrator_voice_settings
    user = character_instance.character&.user

    if user
      user.narrator_settings
    else
      {
        voice_type: TtsService::DEFAULT_VOICE,
        voice_pitch: 0.0,
        voice_speed: 1.0
      }
    end
  end

  # Get speaker's voice settings
  # @param speaker [Character, CharacterInstance, nil]
  # @return [Hash]
  def speaker_voice_settings(speaker)
    char = extract_character(speaker)

    if char&.respond_to?(:voice_settings)
      char.voice_settings
    else
      {
        voice_type: TtsService::DEFAULT_VOICE,
        voice_pitch: 0.0,
        voice_speed: 1.0
      }
    end
  end

  # Extract character from speaker object
  # @param speaker [Character, CharacterInstance, nil]
  # @return [Character, nil]
  def extract_character(speaker)
    case speaker
    when Character
      speaker
    when CharacterInstance
      speaker.character
    else
      nil
    end
  end

  # Extract speaker name from speaker object
  # @param speaker [Character, CharacterInstance, nil]
  # @return [String, nil]
  def extract_speaker_name(speaker)
    char = extract_character(speaker)
    char&.full_name
  end

  # Estimate audio duration based on text length and speed
  # Average speaking rate is ~150 words per minute at 1.0x speed
  # @param text [String]
  # @param speed [Float]
  # @return [Float] estimated seconds
  def estimate_duration(text, speed)
    words = text.split.count
    base_duration = words / 2.5 # ~150 words per minute = 2.5 words per second
    base_duration / speed.to_f
  end
end
