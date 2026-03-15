# frozen_string_literal: true

require 'cgi'

# CharacterStoryExporter generates plaintext downloads of character stories.
#
# Produces a .txt file with:
# - Header with character name and generation date
# - Chapter headers with title, location, date
# - Log content with HTML stripped
# - CRLF line endings for Windows compatibility
#
# Usage:
#   text = CharacterStoryExporter.to_text(character)
#   # Returns plaintext suitable for .txt download
#
class CharacterStoryExporter
  SEPARATOR = ('=' * 80).freeze

  class << self
    # Generate full story as plain text
    #
    # @param character [Character]
    # @return [String] Plaintext story with CRLF line endings
    def to_text(character)
      chapters = ChapterService.chapters_for(character)
      return no_content_message(character) if chapters.empty?

      lines = []
      lines << header(character)
      lines << ''

      chapters.each_with_index do |chapter, index|
        logs = ChapterService.chapter_content(character, index)
        title = ChapterService.chapter_title(character, index, logs: logs)
        lines << chapter_header(title, chapter)
        lines << ''
        lines.concat(format_logs(logs))
        lines << ''
        lines << ''
      end

      lines.join("\r\n") # Windows-compatible line endings
    rescue StandardError => e
      warn "[CharacterStoryExporter] Export failed: #{e.message}"
      error_message(character)
    end

    # Strip HTML from text, preserving readability
    #
    # Converts <br> tags to newlines before stripping other HTML.
    # This ensures line breaks in the original content are preserved.
    # Also decodes HTML entities like &nbsp;, &lt;, &amp;.
    #
    # @param html [String, nil]
    # @return [String]
    def strip_html(html)
      return '' if html.nil?

      # Convert <br> to newlines first
      text = html.gsub(/<br\s*\/?>/i, "\n")

      # Strip remaining HTML tags
      text = text.gsub(/<[^>]*>/, '')

      # Decode HTML entities
      CGI.unescape_html(text)
    end

    private

    # Generate the header section
    #
    # @param character [Character]
    # @return [String]
    def header(character)
      [
        "THE STORY OF #{character.full_name.upcase}",
        "Generated: #{Time.now.strftime('%B %d, %Y')}"
      ].join("\r\n")
    end

    # Generate a chapter header
    #
    # @param title [String] Chapter title
    # @param chapter [Hash] Chapter metadata with :start_time, :location
    # @return [String]
    def chapter_header(title, chapter)
      date_str = chapter[:start_time]&.strftime('%B %d, %Y') || 'Unknown date'
      location = chapter[:location] || 'Unknown location'

      [
        SEPARATOR,
        title.upcase,
        "Location: #{location}",
        "Date: #{date_str}",
        SEPARATOR
      ].join("\r\n")
    end

    # Format logs for text output
    #
    # Uses html_content if available (and non-empty), otherwise falls back to content.
    # All HTML is stripped from the output.
    #
    # @param logs [Array<RpLog>]
    # @return [Array<String>]
    def format_logs(logs)
      logs.map do |log|
        # Prefer html_content if available and non-empty, otherwise use content
        # Note: In Ruby, empty string is truthy, so we must check explicitly
        raw_content = if log.html_content.nil? || log.html_content.empty?
          log.content
        else
          log.html_content
        end
        strip_html(raw_content)
      end
    end

    # Generate a message for characters with no story content
    #
    # @param character [Character]
    # @return [String]
    def no_content_message(character)
      [
        "THE STORY OF #{character.full_name.upcase}",
        "Generated: #{Time.now.strftime('%B %d, %Y')}",
        '',
        'No story content yet.',
        '',
        "Your character's roleplay logs will appear here once you start playing."
      ].join("\r\n")
    end

    # Generate an error message when export fails
    #
    # @param character [Character]
    # @return [String]
    def error_message(character)
      [
        "THE STORY OF #{character.full_name.upcase}",
        "Generated: #{Time.now.strftime('%B %d, %Y')}",
        '',
        'Error: Unable to generate story export.',
        'Please try again later.'
      ].join("\r\n")
    end
  end
end
