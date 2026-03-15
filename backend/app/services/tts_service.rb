# frozen_string_literal: true

# Text-to-Speech service using Google Cloud TTS with Chirp 3 HD voices.
# Handles audio synthesis, file management, and voice configuration.
class TtsService
  extend ResultHandler

  # Delegate to centralized GameConfig for configurability
  def self.audio_dir = GameConfig::Tts.audio_dir
  AUDIO_CLEANUP_MINUTES = GameConfig::Tts::AUDIO_CLEANUP_MINUTES
  MAX_TEXT_LENGTH = GameConfig::Tts::MAX_TEXT_LENGTH

  # Chirp 3 HD voices organized by gender
  # Voice names are the short names (e.g., 'Kore' not 'en-US-Chirp3-HD-Kore')
  # Full list from Google Cloud TTS documentation (30 voices total)
  CHIRP3_HD_VOICES = {
    female: {
      'Achernar' => { description: 'Bright, celestial', locale: 'en-US' },
      'Aoede' => { description: 'Clear, musical', locale: 'en-US' },
      'Autonoe' => { description: 'Warm, gentle', locale: 'en-US' },
      'Callirrhoe' => { description: 'Flowing, melodic', locale: 'en-US' },
      'Despina' => { description: 'Soft, airy', locale: 'en-US' },
      'Erinome' => { description: 'Mysterious, deep', locale: 'en-US' },
      'Gacrux' => { description: 'Strong, resonant', locale: 'en-US' },
      'Kore' => { description: 'Natural, balanced', locale: 'en-US' },
      'Laomedeia' => { description: 'Ethereal, smooth', locale: 'en-US' },
      'Leda' => { description: 'Warm, friendly', locale: 'en-US' },
      'Pulcherrima' => { description: 'Bright, lovely', locale: 'en-US' },
      'Sulafat' => { description: 'Rich, expressive', locale: 'en-US' },
      'Vindemiatrix' => { description: 'Mature, wise', locale: 'en-US' },
      'Zephyr' => { description: 'Airy, light', locale: 'en-US' }
    },
    male: {
      'Achird' => { description: 'Strong, authoritative', locale: 'en-US' },
      'Algenib' => { description: 'Bold, commanding', locale: 'en-US' },
      'Algieba' => { description: 'Confident, clear', locale: 'en-US' },
      'Alnilam' => { description: 'Deep, resonant', locale: 'en-US' },
      'Charon' => { description: 'Deep, mysterious', locale: 'en-US' },
      'Enceladus' => { description: 'Icy, precise', locale: 'en-US' },
      'Fenrir' => { description: 'Intense, dramatic', locale: 'en-US' },
      'Iapetus' => { description: 'Measured, thoughtful', locale: 'en-US' },
      'Orus' => { description: 'Mysterious, deep', locale: 'en-US' },
      'Puck' => { description: 'Playful, mischievous', locale: 'en-US' },
      'Rasalgethi' => { description: 'Rich, baritone', locale: 'en-US' },
      'Sadachbia' => { description: 'Warm, friendly', locale: 'en-US' },
      'Sadaltager' => { description: 'Calm, steady', locale: 'en-US' },
      'Schedar' => { description: 'Royal, dignified', locale: 'en-US' },
      'Umbriel' => { description: 'Soft, shadowy', locale: 'en-US' },
      'Zubenelgenubi' => { description: 'Exotic, distinctive', locale: 'en-US' }
    }
  }.freeze

  # Default voice if none specified
  DEFAULT_VOICE = GameConfig::Tts::DEFAULT_VOICE
  DEFAULT_LOCALE = GameConfig::Tts::DEFAULT_LOCALE

  class << self
    extend ResultHandler

    # Synthesize text to audio file
    # @param text [String] text to synthesize
    # @param voice_type [String] Chirp 3 HD voice name (e.g., 'Kore', 'Charon')
    # @param pitch [Float] pitch adjustment (-20.0 to +20.0), default 0.0
    # @param speed [Float] speaking rate (0.25 to 4.0), default 1.0
    # @param locale [String] language locale (e.g., 'en-US')
    # @return [Result] Result with filename and audio_url in data
    def synthesize(text, voice_type: DEFAULT_VOICE, pitch: 0.0, speed: 1.0, locale: DEFAULT_LOCALE)
      return error('TTS not available') unless available?
      return error('Text is required') if text.nil? || text.strip.empty?
      return error('Text too long') if text.length > MAX_TEXT_LENGTH

      # Clean the text for TTS
      clean_text = sanitize_text(text)
      return error('No readable text after sanitization') if clean_text.empty?

      # Generate unique filename
      filename = generate_filename

      begin
        # Create client and synthesize
        client = create_client

        # Build the voice name (e.g., 'en-US-Chirp3-HD-Kore')
        voice_name = build_voice_name(voice_type, locale)

        # Build request
        input = { text: clean_text }
        voice = {
          language_code: locale,
          name: voice_name
        }
        audio_config = {
          audio_encoding: :MP3,
          speaking_rate: speed.to_f.clamp(GameConfig::Tts::SPEED_RANGE.min, GameConfig::Tts::SPEED_RANGE.max),
          pitch: pitch.to_f.clamp(GameConfig::Tts::PITCH_RANGE.min, GameConfig::Tts::PITCH_RANGE.max)
        }

        response = client.synthesize_speech(
          input: input,
          voice: voice,
          audio_config: audio_config
        )

        # Ensure directory exists
        FileUtils.mkdir_p(audio_dir)

        # Write audio file
        filepath = File.join(audio_dir, "#{filename}.mp3")
        File.open(filepath, 'wb') { |f| f.write(response.audio_content) }

        # Schedule cleanup
        schedule_cleanup(filename)

        success('Audio synthesized', data: { filename: filename, audio_url: "/audios/#{filename}.mp3" })
      rescue Google::Cloud::Error => e
        error("Google Cloud TTS error: #{e.message}")
      rescue StandardError => e
        error("TTS synthesis failed: #{e.message}")
      end
    end

    # Generate a preview audio sample for a voice
    # @param voice_type [String] voice name
    # @param speed [Float] speaking rate (0.25 to 4.0), default 1.0
    # @param pitch [Float] pitch adjustment (-20.0 to +20.0), default 0.0
    # @param locale [String] locale (default 'en-US')
    # @return [Hash] synthesis result
    def generate_preview(voice_type, speed: 1.0, pitch: 0.0, locale: DEFAULT_LOCALE)
      sample_text = "Hello, this is a sample of the #{voice_type} voice. " \
                    "The quick brown fox jumps over the lazy dog."
      synthesize(sample_text, voice_type: voice_type, speed: speed, pitch: pitch, locale: locale)
    end

    # Get available voices grouped by gender
    # @return [Hash] { female: { 'Kore' => {...}, ... }, male: { 'Charon' => {...}, ... } }
    def available_voices
      CHIRP3_HD_VOICES
    end

    # Get flat list of all voice names
    # @return [Array<String>]
    def voice_names
      CHIRP3_HD_VOICES.values.flat_map(&:keys)
    end

    # Check if a voice name is valid
    # @param voice_name [String]
    # @return [Boolean]
    def valid_voice?(voice_name)
      voice_names.include?(voice_name)
    end

    # Get voice info (description, locale, gender)
    # @param voice_name [String]
    # @return [Hash, nil]
    def voice_info(voice_name)
      CHIRP3_HD_VOICES.each do |gender, voices|
        if voices.key?(voice_name)
          return voices[voice_name].merge(gender: gender, name: voice_name)
        end
      end
      nil
    end

    # Get voices by gender
    # @param gender [Symbol] :female or :male
    # @return [Hash]
    def voices_by_gender(gender)
      CHIRP3_HD_VOICES[gender] || {}
    end

    # Check if TTS service is available
    # Uses Google Application Default Credentials (ADC) - no explicit credentials needed
    # if user has run `gcloud auth application-default login`
    # @return [Boolean]
    def available?
      # If explicit credentials path is set, use it
      credentials_path = GameSetting.get('google_tts_credentials_path')
      return true if credentials_path && !credentials_path.empty?

      # ADC doesn't require env var - gcloud auth handles it automatically
      # Just return true and let actual synthesis calls fail gracefully if not configured
      true
    end

    # Test the TTS connection
    # @return [Result]
    def test_connection
      return error('TTS not configured') unless available?

      result = synthesize('Test', voice_type: DEFAULT_VOICE)
      if result[:success]
        # Clean up test file
        File.delete(File.join(audio_dir, "#{result[:filename]}.mp3")) rescue nil
        success('TTS connection successful')
      else
        result
      end
    end

    # Clean up old audio files
    # @param max_age_minutes [Integer] delete files older than this
    # @return [Integer] number of files deleted
    def cleanup_old_files(max_age_minutes = AUDIO_CLEANUP_MINUTES)
      return 0 unless Dir.exist?(audio_dir)

      deleted = 0
      cutoff = Time.now - (max_age_minutes * 60)

      Dir.glob(File.join(audio_dir, '*.mp3')).each do |filepath|
        # Skip sample/permanent files
        next if filepath.include?('/samples/')
        next if File.basename(filepath).start_with?('sample_')

        if File.mtime(filepath) < cutoff
          File.delete(filepath) rescue nil
          deleted += 1
        end
      end

      deleted
    end

    private

    # Create Google Cloud TTS client
    def create_client
      require 'google/cloud/text_to_speech'

      credentials_path = GameSetting.get('google_tts_credentials_path')

      if credentials_path && !credentials_path.empty? && File.exist?(credentials_path)
        Google::Cloud::TextToSpeech.text_to_speech do |config|
          config.credentials = credentials_path
        end
      else
        # Use default credentials (GOOGLE_APPLICATION_CREDENTIALS env var)
        Google::Cloud::TextToSpeech.text_to_speech
      end
    end

    # Build full voice name for Chirp 3 HD
    # @param short_name [String] e.g., 'Kore'
    # @param locale [String] e.g., 'en-US'
    # @return [String] e.g., 'en-US-Chirp3-HD-Kore'
    def build_voice_name(short_name, locale)
      # Normalize voice name
      voice = valid_voice?(short_name) ? short_name : DEFAULT_VOICE
      "#{locale}-Chirp3-HD-#{voice}"
    end

    # Sanitize text for TTS (remove HTML, special chars, etc.)
    # @param text [String]
    # @return [String]
    def sanitize_text(text)
      return '' if text.nil?

      result = text.dup

      # Remove HTML tags
      result = result.gsub(/<[^>]+>/, ' ')

      # Decode HTML entities
      result = result.gsub('&lt;', '<')
                     .gsub('&gt;', '>')
                     .gsub('&amp;', '&')
                     .gsub('&quot;', '"')
                     .gsub('&nbsp;', ' ')

      # Remove bracketed content (OOC, etc.)
      result = result.gsub(/\([^)]*\)/, '')
                     .gsub(/\[[^\]]*\]/, '')

      # Normalize whitespace
      result = result.gsub(/\s+/, ' ').strip

      # Convert to ASCII-safe (remove exotic unicode)
      result.encode('ASCII', invalid: :replace, undef: :replace, replace: '')
    end

    # Generate unique filename for audio file
    # @return [String]
    def generate_filename
      "tts_#{SecureRandom.hex(8)}_#{Time.now.to_i}"
    end

    # Schedule file for cleanup (in background thread)
    # @param filename [String]
    def schedule_cleanup(filename)
      Thread.new do
        sleep(AUDIO_CLEANUP_MINUTES * 60)
        filepath = File.join(audio_dir, "#{filename}.mp3")
        File.delete(filepath) if File.exist?(filepath)
      rescue StandardError => e
        warn "[TTSService] Failed to cleanup file '#{filename}': #{e.message}"
      end
    end
  end
end
