# frozen_string_literal: true

require 'erb'

module AutoGm
  # Shared formatting helpers for Auto GM services.
  # Provides common methods for formatting prompts and messages.
  #
  # Usage:
  #   class AutoGmMyService
  #     extend AutoGmFormatHelper
  #
  #     def self.do_something
  #       format_list(['a', 'b', 'c'])
  #     end
  #   end
  #
  module AutoGmFormatHelper
    # Format a list of items for LLM prompts
    # @param items [Array, nil] items to format
    # @return [String] comma-separated list or 'none'
    def format_list(items)
      return 'none' if items.nil? || items.empty?

      items.map { |i| i.is_a?(Hash) ? i['name'] || i[:name] : i.to_s }.join(', ')
    end

    # Convert markdown bold/italic to HTML tags in already-escaped text.
    # Process bold first so ** doesn't match as two separate *.
    # @param escaped_html [String] HTML-escaped text containing markdown markers
    # @return [String] text with markdown converted to HTML tags
    def markdown_to_html(escaped_html)
      result = escaped_html.gsub(/\*\*(.+?)\*\*/m, '<strong>\1</strong>')
      result.gsub(/\*(.+?)\*/m, '<em>\1</em>')
    end

    # Strip markdown markers from plain text
    # @param text [String] text with markdown markers
    # @return [String] text without markdown markers
    def strip_markdown(text)
      result = text.gsub(/\*\*(.+?)\*\*/m, '\1')
      result.gsub(/\*(.+?)\*/m, '\1')
    end

    # Format a GM narration message with HTML
    # @param text [String] the message text
    # @return [Hash] formatted message with content, html, and type
    def format_gm_message(text)
      format_auto_gm_message(text, css_class: 'auto-gm-narration', type: 'auto_gm_narration', wrapper: 'em')
    end

    # Format a revelation message
    # @param secret [String] the secret being revealed
    # @return [Hash] formatted message
    def format_revelation_message(secret)
      format_auto_gm_message(
        secret,
        prefix: 'Secret Revealed:',
        css_class: 'auto-gm-revelation',
        type: 'auto_gm_revelation'
      )
    end

    # Format a twist message
    # @param twist [String] the twist text
    # @return [Hash] formatted message
    def format_twist_message(twist)
      format_auto_gm_message(
        twist,
        prefix: 'TWIST!',
        css_class: 'auto-gm-twist',
        type: 'auto_gm_twist'
      )
    end

    # Format a random event message
    # @param text [String] the event text
    # @return [Hash] formatted message with content, html, and type
    def format_event_message(text)
      format_auto_gm_message(text, prefix: 'Random Event:', css_class: 'auto-gm-event', type: 'auto_gm_random_event')
    end

    # Format a stage transition message
    # Only shows the stage name as an atmospheric separator — the description is
    # internal sketch notes and should not be shown to players.
    # @param stage_info [Hash] stage data with 'name' and 'description'
    # @return [Hash] formatted message
    def format_stage_message(stage_info)
      name = stage_info['name'] || stage_info[:name] || 'The story continues'

      {
        content: "— #{name} —",
        html: "<div class='auto-gm-stage'>— #{ERB::Util.html_escape(name)} —</div>",
        type: 'auto_gm_stage_transition'
      }
    end

    private

    # Generic helper to format Auto GM messages
    # @param text [String] the message text
    # @param prefix [String, nil] optional prefix (e.g., "TWIST!")
    # @param css_class [String] CSS class for the div
    # @param type [String] message type
    # @param wrapper [String, nil] optional HTML wrapper element (e.g., 'em')
    # @return [Hash] formatted message
    def format_auto_gm_message(text, css_class:, type:, prefix: nil, wrapper: nil)
      # Strip HTML tags that LLMs sometimes generate in narrative text
      clean_text = text.to_s.gsub(/<\/?(?:em|strong|b|i|p|br|span)[^>]*>/i, '')
      escaped = ERB::Util.html_escape(clean_text)

      rich_text = markdown_to_html(escaped)
      plain_text = strip_markdown(clean_text)

      content = prefix ? "#{prefix} #{plain_text}" : plain_text
      html_content = if prefix
                       "<strong>#{prefix}</strong> #{rich_text}"
                     elsif wrapper
                       "<#{wrapper}>#{rich_text}</#{wrapper}>"
                     else
                       rich_text
                     end

      {
        content: content,
        html: "<div class='#{css_class}'>#{html_content}</div>",
        type: type
      }
    end
  end
end
