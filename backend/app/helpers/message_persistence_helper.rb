# frozen_string_literal: true

# Provides message persistence helpers for communication commands.
#
# Consolidates the duplicate persist_message methods found in say, emote,
# whisper, private_message, and say_to commands.
#
# Usage:
#   class MyCommand < Commands::Base::Command
#     include MessagePersistenceHelper
#
#     def perform_command(parsed_input)
#       message = persist_room_message("Hello, world!", message_type: 'say')
#       # or for targeted messages:
#       message = persist_targeted_message("Hello!", target_instance, message_type: 'whisper')
#     end
#   end
#
module MessagePersistenceHelper
  # ============================================
  # Combined Validation Helpers
  # ============================================

  # Validate message content for spam and abuse in one call.
  # Consolidates the duplicate check + abuse check pattern found in all communication commands.
  #
  # @param text [String] The message content to validate
  # @param message_type [String] Type of message (say, emote, whisper, etc.)
  # @param duplicate_error [String] Error message for duplicate detection (optional)
  # @return [Hash, nil] Returns error_result hash if validation fails, nil if valid
  #
  # Usage:
  #   error = validate_message_content(text, message_type: 'say')
  #   return error if error
  def validate_message_content(text, message_type:, duplicate_error: nil)
    # Check if user is muted (temp mute from moderation)
    if user_muted?
      mute_info = current_user&.mute_info
      remaining = mute_info ? mute_info[:remaining_display] : 'some time'
      return error_result("You are temporarily muted. Time remaining: #{remaining}")
    end

    # Check for recent duplicate
    if has_recent_duplicate?(text, message_type: message_type)
      default_msg = "You recently sent something similar."
      return error_result(duplicate_error || default_msg)
    end

    # Check for abuse
    abuse_result = check_for_abuse(text, message_type: message_type)
    unless abuse_result[:allowed]
      return error_result(abuse_result[:reason] || "Your message is being reviewed.")
    end

    nil # Valid
  end

  # Check if the current user is muted
  #
  # @return [Boolean] True if user is muted
  def user_muted?
    user = current_user
    return false unless user

    # Check if mute has expired
    user.check_mute_expired!

    user.muted?
  end

  # Get the current user from character_instance
  #
  # @return [User, nil]
  def current_user
    character_instance&.character&.user
  end

  # Check if character is gagged and return appropriate error.
  # Consolidates the gag check pattern found in say and emote commands.
  #
  # @param action_description [String] Description of what they're trying to do (default: "speak")
  # @return [Hash, nil] Returns error_result hash if gagged, nil if not gagged
  #
  # Usage:
  #   error = check_not_gagged("express yourself")
  #   return error if error
  def check_not_gagged(action_description = "speak")
    return nil unless character_instance&.gagged?

    error_result("You try to #{action_description} but can only make muffled sounds through your gag.")
  end

  # Broadcast a personalized message to room observers (excluding specified characters).
  # Consolidates the observer broadcast pattern in whisper, private_message, and say_to.
  #
  # @param message [String] The message to broadcast
  # @param exclude_instances [Array<CharacterInstance>] Characters to exclude from broadcast
  # @yield [viewer_instance] Optional block to customize message per viewer
  # @return [void]
  #
  # Usage:
  #   # Simple usage - same message to all observers
  #   broadcast_to_observers_personalized(obscured_message, exclude_instances: [character_instance, target])
  #
  #   # With custom per-viewer formatting
  #   broadcast_to_observers_personalized(message, exclude_instances: [self_instance]) do |viewer|
  #     substitute_names_for_viewer(message, viewer)
  #   end
  def broadcast_to_observers_personalized(message, exclude_instances: [], **options)
    online_room_characters(exclude: exclude_instances).eager(:character).each do |viewer_instance|
      personalized = if block_given?
                       yield(viewer_instance)
                     else
                       substitute_names_for_viewer(message, viewer_instance)
                     end
      send_to_character(viewer_instance, personalized, **options)
    end
  end

  # ============================================
  # Core Methods
  # ============================================

  # Check message for abuse before allowing it through
  #
  # @param content [String] The message content to check
  # @param message_type [String] Type of message (say, emote, whisper, etc.)
  # @return [Hash] { allowed: Boolean, delayed: Boolean, check_id: Integer|nil, reason: String|nil }
  def check_for_abuse(content, message_type:)
    AbuseMonitoringService.check_message(
      content: content,
      message_type: message_type,
      character_instance: character_instance,
      context: build_abuse_context
    )
  end

  # Persist a room-wide message (say, emote, yell, etc.)
  #
  # @param content [String] the formatted message content
  # @param message_type [String] type of message ('say', 'emote', 'yell', etc.)
  # @return [Message, nil] the created message or nil on failure
  def persist_room_message(content, message_type:)
    Message.create(
      character_instance_id: character_instance.id,
      reality_id: character_instance.reality_id,
      room_id: character_instance.current_room_id,
      content: content,
      message_type: message_type
    )
  rescue StandardError => e
    warn "Failed to persist #{message_type} message: #{e.class} - #{e.message}"
    nil
  end

  # Persist a targeted message (whisper, PM, say_to, etc.)
  #
  # @param content [String] the formatted message content
  # @param target_instance [CharacterInstance] the target character
  # @param message_type [String] type of message ('whisper', 'pm', 'say_to', etc.)
  # @return [Message, nil] the created message or nil on failure
  def persist_targeted_message(content, target_instance, message_type:)
    Message.create(
      character_instance_id: character_instance.id,
      target_character_instance_id: target_instance&.id,
      reality_id: character_instance.reality_id,
      room_id: character_instance.current_room_id,
      content: content,
      message_type: message_type
    )
  rescue StandardError => e
    warn "Failed to persist #{message_type} message: #{e.class} - #{e.message}"
    nil
  end

  # Check for recent duplicate messages to prevent spam
  #
  # @param text [String] the new message text to check
  # @param message_type [String] type of message to check against
  # @param window_minutes [Integer] time window in minutes (default: 5)
  # @param similarity_threshold [Float] Levenshtein ratio threshold (default: 0.8)
  # @return [Boolean] true if a similar recent message exists
  def has_recent_duplicate?(text, message_type:, window_minutes: 5)
    cutoff = Time.now - (window_minutes * 60)

    recent_messages = Message.where(
      character_instance_id: character_instance.id,
      message_type: message_type
    ).where { created_at > cutoff }
                             .order(Sequel.desc(:created_at))
                             .limit(10)

    recent_messages.any? do |msg|
      content = extract_message_content(msg.content)
      similar_text?(content, text)
    end
  end

  private

  # Extract the actual spoken text from formatted messages
  # Handles formats like: "Name says, 'text'" or "'text' says Name."
  #
  # @param formatted_message [String] the full formatted message
  # @return [String] the extracted spoken text
  def extract_message_content(formatted_message)
    return if formatted_message.nil?

    # Matches: "Name says, 'text'" - extracts text
    if formatted_message =~ /, '(.+)'$/
      return ::Regexp.last_match(1)
    end

    # Matches: "'text' says Name." - extracts text
    if formatted_message =~ /^'(.+)' .+ says/
      return ::Regexp.last_match(1)
    end

    formatted_message
  end

  # Check if two texts are similar (for duplicate detection)
  # IMPORTANT: This should only catch exact/near-exact duplicates, not
  # messages that happen to share some words.
  #
  # @param text1 [String] first text
  # @param text2 [String] second text
  # @return [Boolean] true if texts are similar enough to be duplicates
  def similar_text?(text1, text2)
    return false if text1.nil? || text2.nil?

    t1 = text1.to_s.downcase.strip
    t2 = text2.to_s.downcase.strip

    # Exact match
    return true if t1 == t2

    # Normalize: remove trailing punctuation and compare
    t1_normalized = t1.gsub(/[.!?,;:]+$/, '')
    t2_normalized = t2.gsub(/[.!?,;:]+$/, '')
    return true if t1_normalized == t2_normalized

    # Very short texts (< 10 chars) - only block exact matches (handled above)
    # This prevents blocking "hi" after saying "hi there"
    return false if t1.length < 10 || t2.length < 10

    # Only check substring containment for longer messages (20+ chars)
    # and only if the contained string is substantial (80%+ of the container)
    if t1.length >= 20 && t2.length >= 20
      if t1_normalized.include?(t2_normalized)
        return t2_normalized.length.to_f / t1_normalized.length >= 0.8
      end
      if t2_normalized.include?(t1_normalized)
        return t1_normalized.length.to_f / t2_normalized.length >= 0.8
      end
    end

    # For medium-length messages (10-30 chars), only block high-confidence duplicates
    # Use a stricter threshold to avoid false positives
    return false if t1.length < 30 || t2.length < 30

    # For longer messages: use character frequency comparison with strict threshold
    freq1 = t1_normalized.chars.tally
    freq2 = t2_normalized.chars.tally

    # Calculate overlap using minimum frequencies
    common_count = 0
    freq1.each do |char, count|
      common_count += [count, freq2[char] || 0].min
    end

    max_length = [t1_normalized.length, t2_normalized.length].max
    ratio = common_count.to_f / max_length

    # Only flag as duplicate if 90%+ character overlap (very strict)
    ratio >= 0.9
  end

  # Build context for abuse checking
  #
  # @return [Hash] Context including room name and recent messages
  def build_abuse_context
    {
      room_name: location&.name,
      recent_messages: recent_room_messages(5),
      character_name: character&.full_name
    }
  end

  # Get recent messages in the current room
  #
  # @param count [Integer] Number of messages to retrieve
  # @return [Array<String>] Recent message contents
  def recent_room_messages(count)
    return [] unless location&.id

    Message.where(room_id: location.id)
           .order(Sequel.desc(:created_at))
           .limit(count)
           .map(&:content)
  rescue StandardError => e
    warn "[MessagePersistenceHelper] Recent messages error: #{e.message}" if ENV['DEBUG']
    []
  end
end
