# frozen_string_literal: true

# Provides string validation helpers that replace Rails' ActiveSupport methods.
#
# This is a pure Ruby implementation since Firefly uses Sequel, not Rails.
# These methods replace the common Rails patterns: .blank?, .present?
#
# Usage:
#   class MyService
#     include StringHelper
#
#     def process(text)
#       return if blank?(text)
#       # process text...
#     end
#   end
#
module StringHelper
  # Allow calling as both StringHelper.blank?(val) and instance method blank?(val)
  extend self

  # Check if a value is nil or empty (like Rails' blank?)
  #
  # @param value [Object] The value to check
  # @return [Boolean] true if value is nil, empty, or whitespace-only
  #
  # @example
  #   blank?(nil)       # => true
  #   blank?('')        # => true
  #   blank?('   ')     # => true
  #   blank?('hello')   # => false
  #   blank?(0)         # => false
  #   blank?([])        # => true
  #   blank?({})        # => true
  def blank?(value)
    case value
    when NilClass
      true
    when String
      value.strip.empty?
    when Array, Hash
      value.empty?
    when FalseClass
      true
    else
      false
    end
  end

  # Check if a value is present (not blank) - like Rails' present?
  #
  # @param value [Object] The value to check
  # @return [Boolean] true if value is not blank
  #
  # @example
  #   present?(nil)       # => false
  #   present?('')        # => false
  #   present?('hello')   # => true
  #   present?(0)         # => true
  #   present?([1, 2])    # => true
  def present?(value)
    !blank?(value)
  end

  # @deprecated Use present? instead (identical behavior)
  # Check if text is valid (not nil and not empty/whitespace)
  # Kept for backward compatibility with existing specs
  #
  # @param text [String, nil] The text to validate
  # @return [Boolean] true if text contains non-whitespace content
  def valid_text?(text)
    present?(text)
  end

  # Truncate text to a maximum length with ellipsis
  # Similar to Rails' String#truncate
  #
  # @param text [String, nil] The text to truncate
  # @param max_length [Integer] Maximum length including ellipsis
  # @param omission [String] Omission string (default: '...')
  # @return [String] Truncated text or original if under max_length
  #
  # @example
  #   truncate('Hello World', 8)        # => 'Hello...'
  #   truncate('Short', 10)             # => 'Short'
  #   truncate(nil, 10)                 # => ''
  #   truncate('Long text', 7, '…')     # => 'Long t…'
  def truncate(text, max_length, omission = '...')
    return '' if text.nil? || text.empty?
    return text if text.length <= max_length

    "#{text[0, max_length - omission.length]}#{omission}"
  end

  # Strip HTML tags from text
  # Handles both <tag> and <tag attr="value"> patterns
  #
  # @param text [String, nil] The text containing HTML tags
  # @return [String] Text with all HTML tags removed
  #
  # @example
  #   strip_html('<b>Hello</b>')           # => 'Hello'
  #   strip_html('<span class="red">Hi</span>')  # => 'Hi'
  #   strip_html(nil)                      # => ''
  def strip_html(text)
    return '' if text.nil?

    text.to_s.gsub(/<[^>]*>/, '')
  end

  # Decode common HTML entities back to their characters
  #
  # @param text [String, nil] The text with HTML entities
  # @return [String] Text with entities decoded
  #
  # @example
  #   decode_html_entities('&lt;test&gt;')  # => '<test>'
  #   decode_html_entities('&amp;')         # => '&'
  #   decode_html_entities('&quot;hi&quot;') # => '"hi"'
  def decode_html_entities(text)
    return '' if text.nil?

    text.to_s
        .gsub('&lt;', '<')
        .gsub('&gt;', '>')
        .gsub('&amp;', '&')
        .gsub('&quot;', '"')
        .gsub('&#39;', "'")
        .gsub('&nbsp;', ' ')
  end

  # Strip HTML tags and decode entities in one operation
  # Useful for converting styled game text to plain text
  #
  # @param text [String, nil] The text to clean
  # @return [String] Clean plain text
  #
  # @example
  #   strip_and_decode('<b>&lt;sword&gt;</b>')  # => '<sword>'
  def strip_and_decode(text)
    decode_html_entities(strip_html(text))
  end

  # Sanitize user input HTML to allow safe formatting tags while stripping
  # dangerous attributes and unwanted elements (e.g. CSS styles from copy-paste)
  #
  # Allowed tags: span, b, strong, i, em, u, s, strike, br, font, color
  # Allowed attributes: color, style (only color property), class
  # Strips: style properties other than color, script tags, event handlers, etc.
  #
  # @param text [String, nil] The user input text
  # @return [String] Sanitized text with safe formatting preserved
  def sanitize_user_html(text)
    return '' if text.nil?

    str = text.to_s
    # Quick check: if no HTML at all, return as-is
    return str unless str.include?('<') || str.include?('style=')

    # Remove script/iframe tags entirely (opening + content + closing, and self-closing)
    str = str.gsub(/<\s*(script|iframe|object|embed|form|input|textarea|button|select)[^>]*>.*?<\/\s*\1\s*>/mi, '')
    str = str.gsub(/<\s*(?:script|iframe|object|embed|form|input|textarea|button|select)[^>]*\/?>/i, '')

    # Remove event handler attributes (onclick, onerror, etc.)
    str = str.gsub(/\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)/i, '')

    # Process style attributes: keep only color, strip everything else
    str = str.gsub(/\bstyle\s*=\s*"([^"]*)"/i) do
      styles = Regexp.last_match(1)
      # Extract only color property
      color_match = styles.match(/(?:^|;)\s*color\s*:\s*([^;]+)/i)
      if color_match
        "style=\"color: #{color_match[1].strip}\""
      else
        '' # Strip the entire style attribute if no color
      end
    end

    # Same for single-quoted style attributes
    str = str.gsub(/\bstyle\s*=\s*'([^']*)'/i) do
      styles = Regexp.last_match(1)
      color_match = styles.match(/(?:^|;)\s*color\s*:\s*([^;]+)/i)
      if color_match
        "style=\"color: #{color_match[1].strip}\""
      else
        ''
      end
    end

    str
  end

  # Sanitize text for canvas/map rendering
  # Removes HTML tags and special characters that interfere with canvas drawing
  #
  # @param text [String, nil] The text to sanitize
  # @return [String] Sanitized text safe for canvas
  #
  # @example
  #   sanitize_for_canvas('<b>Town|Square</b>')  # => 'Town Square'
  def sanitize_for_canvas(text)
    return '' if text.nil?

    text.to_s.gsub(/<[^>]*>/, '').gsub(/[|;:]/, ' ').strip
  end

  # Clean text for plain name extraction (strip HTML and trim)
  # Common pattern for getting clean names from styled item/character names
  #
  # @param text [String, nil] The styled text
  # @return [String] Clean, trimmed name
  #
  # @example
  #   plain_name('<span class="rare">Magic Sword</span>')  # => 'Magic Sword'
  def plain_name(text)
    strip_html(text).strip
  end

  # Format a time as a human-readable relative string (e.g., "5 minutes ago")
  # Replaces duplicated time_ago/format_time_ago methods across commands
  #
  # @param time [Time, nil] The time to format
  # @param unknown_text [String] Text to return if time is nil (default: 'Unknown')
  # @return [String] Human-readable relative time string
  #
  # @example
  #   time_ago(Time.now - 30)        # => 'just now'
  #   time_ago(Time.now - 120)       # => '2 minutes ago'
  #   time_ago(Time.now - 7200)      # => '2 hours ago'
  #   time_ago(Time.now - 172800)    # => '2 days ago'
  #   time_ago(nil)                  # => 'Unknown'
  def time_ago(time, unknown_text: 'Unknown')
    return unknown_text unless time

    seconds = (Time.now - time).to_i
    return 'just now' if seconds < 60

    minutes = seconds / 60
    return "#{minutes} minute#{'s' if minutes != 1} ago" if minutes < 60

    hours = minutes / 60
    return "#{hours} hour#{'s' if hours != 1} ago" if hours < 24

    days = hours / 24
    "#{days} day#{'s' if days != 1} ago"
  end

  # Format a future time as a human-readable relative string
  #
  # @param time [Time, nil] The future time to format
  # @param fallback [String] Text for past times or nil (default: 'TBD')
  # @return [String] Human-readable relative time string
  #
  # @example
  #   time_until(Time.now + 1800)    # => 'In 30 minutes'
  #   time_until(Time.now + 7200)    # => 'In 2 hours'
  #   time_until(Time.now - 100)     # => 'Started 1 minute ago'
  def time_until(time, fallback: 'TBD')
    return fallback unless time

    diff = time - Time.now
    if diff < 0
      "Started #{time_ago(time, unknown_text: fallback).sub(' ago', '')} ago"
    elsif diff < 3600
      "In #{(diff / 60).round} minutes"
    elsif diff < 86_400
      "In #{(diff / 3600).round} hours"
    else
      time.strftime('%b %d at %I:%M %p')
    end
  end

  # =====================
  # Time Utility Methods
  # =====================
  # Common patterns for expiration checks, elapsed time, and duration math.
  # Use these instead of raw `Time.now` comparisons for consistency.

  # Check if a time has passed (is expired)
  # @param expires_at [Time, nil] The expiration time
  # @return [Boolean] true if expired or nil
  #
  # @example
  #   expired?(Time.now - 60)  # => true (1 minute ago)
  #   expired?(Time.now + 60)  # => false (1 minute from now)
  #   expired?(nil)            # => true (nil = expired/never set)
  def expired?(expires_at)
    return true if expires_at.nil?

    Time.now >= expires_at
  end

  # Check if a time has NOT passed (is still active)
  # @param expires_at [Time, nil] The expiration time
  # @return [Boolean] true if still active (not expired)
  #
  # @example
  #   active_until?(Time.now + 60)  # => true
  #   active_until?(Time.now - 60)  # => false
  #   active_until?(nil)            # => false
  def active_until?(expires_at)
    return false if expires_at.nil?

    Time.now < expires_at
  end

  # Get seconds remaining until expiration
  # @param expires_at [Time, nil] The expiration time
  # @return [Integer] Seconds remaining (0 if expired or nil)
  #
  # @example
  #   remaining_seconds(Time.now + 90)  # => 90
  #   remaining_seconds(Time.now - 10)  # => 0
  def remaining_seconds(expires_at)
    return 0 if expires_at.nil?

    [(expires_at - Time.now).to_i, 0].max
  end

  # Get milliseconds remaining until expiration
  # @param expires_at [Time, nil] The expiration time
  # @return [Integer] Milliseconds remaining (0 if expired or nil)
  def remaining_ms(expires_at)
    return 0 if expires_at.nil?

    [((expires_at - Time.now) * 1000).to_i, 0].max
  end

  # Get seconds elapsed since a start time
  # @param started_at [Time, nil] The start time
  # @return [Integer] Seconds elapsed (0 if nil)
  #
  # @example
  #   elapsed_seconds(Time.now - 120)  # => 120
  #   elapsed_seconds(nil)             # => 0
  def elapsed_seconds(started_at)
    return 0 if started_at.nil?

    (Time.now - started_at).to_i
  end

  # Create an expiration time from now
  # @param duration_seconds [Integer] Seconds until expiration
  # @return [Time] The expiration time
  #
  # @example
  #   expires_in(3600)  # => Time 1 hour from now
  def expires_in(duration_seconds)
    Time.now + duration_seconds
  end

  # Check if a time is within a window from now (for recent activity checks)
  # @param time [Time, nil] The time to check
  # @param window_seconds [Integer] The window size in seconds
  # @return [Boolean] true if within window
  #
  # @example
  #   within_window?(Time.now - 30, 60)   # => true (30s ago, 60s window)
  #   within_window?(Time.now - 120, 60)  # => false (120s ago, 60s window)
  def within_window?(time, window_seconds)
    return false if time.nil?

    Time.now - time < window_seconds
  end
end
