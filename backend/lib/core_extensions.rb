# frozen_string_literal: true

require 'rack'
require_relative '../app/helpers/string_helper'

# Pure Ruby alternatives to common Rails/ActiveSupport methods.
# Use these instead of Rails methods in this Sequel-based application.
#
# For blank?/present?/strip_html/decode_html_entities/truncate, use StringHelper
# (the canonical source). This module delegates to StringHelper for those methods
# and provides additional string transformation helpers (titleize, camelize, etc.).
#
# Usage:
#   # Option 1: Include in a class
#   class MyClass
#     include CoreExtensions
#
#     def my_method
#       return if blank?(input)
#       titleize(name)
#     end
#   end
#
#   # Option 2: Call as module methods
#   CoreExtensions.present?(value)
#   CoreExtensions.titleize('some_name')
#
# @see docs/solutions/runtime-errors/rails-methods-in-plain-ruby-prevention.md
#
module CoreExtensions
  module_function

  # Delegate to StringHelper (canonical source) for blank?/present?
  def present?(obj) = StringHelper.present?(obj)
  def blank?(obj) = StringHelper.blank?(obj)

  # Convert string to title case (handles underscores and dashes).
  # Equivalent to ActiveSupport's String#titleize
  #
  # @param str [String, nil] Input string
  # @return [String] Title-cased string
  #
  # @example
  #   titleize('some_category')  # => "Some Category"
  #   titleize('user-profile')   # => "User Profile"
  #   titleize('hello world')    # => "Hello World"
  #   titleize(nil)              # => ""
  #
  def titleize(str)
    return '' if str.nil?

    str.to_s.gsub(/[_-]/, ' ').split.map(&:capitalize).join(' ')
  end

  # Convert string to human-readable format.
  # Equivalent to ActiveSupport's String#humanize
  #
  # @param str [String, nil] Input string
  # @return [String] Human-readable string
  #
  # @example
  #   humanize('left_eye')       # => "Left eye"
  #   humanize('user_profile')   # => "User profile"
  #   humanize(nil)              # => ""
  #
  def humanize(str)
    return '' if str.nil?

    str.to_s.tr('_-', ' ').capitalize
  end

  # Delegate to StringHelper (canonical source) for truncate
  def truncate(str, length, omission: '...')
    StringHelper.truncate(str, length, omission)
  end

  # Truncate string to specified length, breaking at word boundaries.
  #
  # @param str [String, nil] Input string
  # @param length [Integer] Maximum total length (including omission)
  # @param omission [String] Truncation indicator (default: '...')
  # @return [String] Truncated string
  #
  # @example
  #   truncate_words('Hello beautiful world', 15)  # => "Hello..."
  #
  def truncate_words(str, length, omission: '...')
    return '' if str.nil?
    return str if str.length <= length

    truncated = str[0, length - omission.length]
    # Find last word boundary
    last_space = truncated.rindex(' ')

    if last_space
      "#{truncated[0, last_space]}#{omission}"
    else
      "#{truncated}#{omission}"
    end
  end

  # Convert string to snake_case.
  # Equivalent to ActiveSupport's String#underscore
  #
  # Note: Sequel provides Sequel.underscore() which may be preferred.
  #
  # @param str [String, nil] Input string
  # @return [String] snake_cased string
  #
  # @example
  #   underscore('SomeClassName')  # => "some_class_name"
  #   underscore('HTTPServer')     # => "http_server"
  #   underscore(nil)              # => ""
  #
  def underscore(str)
    return '' if str.nil?

    str.to_s
       .gsub(/::/, '/')
       .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
       .tr('-', '_')
       .downcase
  end

  # Convert string to CamelCase (PascalCase).
  # Equivalent to ActiveSupport's String#camelize
  #
  # @param str [String, nil] Input string
  # @return [String] CamelCased string
  #
  # @example
  #   camelize('some_class')     # => "SomeClass"
  #   camelize('http_server')    # => "HttpServer"
  #   camelize(nil)              # => ""
  #
  def camelize(str)
    return '' if str.nil?

    str.to_s.split('_').map(&:capitalize).join
  end

  # Convert string to lower camelCase.
  #
  # @param str [String, nil] Input string
  # @return [String] lowerCamelCase string
  #
  # @example
  #   lower_camelize('some_method')  # => "someMethod"
  #
  def lower_camelize(str)
    return '' if str.nil?

    parts = str.to_s.split('_')
    return '' if parts.empty?

    parts.first.downcase + parts[1..].map(&:capitalize).join
  end

  # Safely call a method on an object that might be nil.
  # Equivalent to ActiveSupport's Object#try
  #
  # Note: Prefer using Ruby's safe navigation operator (&.) instead.
  # This is provided for cases where you need to call with arguments.
  #
  # @param obj [Object, nil] Target object
  # @param method_name [Symbol, String] Method to call
  # @param args [Array] Arguments to pass to the method
  # @param block [Proc] Optional block to pass to the method
  # @return [Object, nil] Result of method call, or nil if object is nil
  #
  # @example
  #   safe_send(user, :name)           # Same as user&.name
  #   safe_send(nil, :name)            # => nil
  #   safe_send(str, :gsub, '_', ' ')  # str&.gsub('_', ' ')
  #
  def safe_send(obj, method_name, *args, &block)
    return nil if obj.nil?
    return nil unless obj.respond_to?(method_name)

    obj.send(method_name, *args, &block)
  end

  # Get ordinal suffix for a number.
  # Equivalent to ActiveSupport's Integer#ordinalize (partial)
  #
  # @param number [Integer] Number to get suffix for
  # @return [String] Number with ordinal suffix
  #
  # @example
  #   ordinalize(1)   # => "1st"
  #   ordinalize(2)   # => "2nd"
  #   ordinalize(3)   # => "3rd"
  #   ordinalize(11)  # => "11th"
  #   ordinalize(21)  # => "21st"
  #
  def ordinalize(number)
    return '' if number.nil?

    abs_number = number.to_i.abs
    suffix = if (11..13).cover?(abs_number % 100)
               'th'
             else
               case abs_number % 10
               when 1 then 'st'
               when 2 then 'nd'
               when 3 then 'rd'
               else 'th'
               end
             end

    "#{number}#{suffix}"
  end

  # Pluralize a word based on count.
  # Simple version - does not handle irregular plurals.
  #
  # @param word [String] Word to pluralize
  # @param count [Integer] Count to determine singular/plural
  # @return [String] Pluralized word (or singular if count is 1)
  #
  # @example
  #   pluralize('item', 1)   # => "item"
  #   pluralize('item', 5)   # => "items"
  #   pluralize('box', 3)    # => "boxes"
  #
  def pluralize(word, count)
    return word if count == 1

    # Simple pluralization rules
    if word.end_with?('s', 'x', 'z', 'ch', 'sh')
      "#{word}es"
    elsif word.end_with?('y') && !%w[a e i o u].include?(word[-2])
      "#{word[0..-2]}ies"
    else
      "#{word}s"
    end
  end

  # Format a count with a pluralized word.
  #
  # @param count [Integer] Number of items
  # @param word [String] Word to pluralize
  # @return [String] Formatted string
  #
  # @example
  #   count_with_word(1, 'item')  # => "1 item"
  #   count_with_word(5, 'item')  # => "5 items"
  #
  def count_with_word(count, word)
    "#{count} #{pluralize(word, count)}"
  end

  # ========================================
  # HTML Escaping and Sanitization
  # ========================================

  # Escape HTML entities to prevent XSS.
  # Uses Rack::Utils.escape_html which is the standard Ruby approach.
  def escape_html(text)
    return '' if text.nil?

    Rack::Utils.escape_html(text.to_s)
  end

  # Delegate to StringHelper (canonical source) for strip_html/decode_html_entities
  def strip_html(text) = StringHelper.strip_html(text)
  def decode_html_entities(text) = StringHelper.decode_html_entities(text)

  # Sanitize text for plain text output (remove HTML, decode entities, normalize whitespace).
  def sanitize_for_plain_text(text)
    return '' if text.nil?

    result = strip_html(text)
    result = decode_html_entities(result)
    result.gsub(/\s+/, ' ').strip
  end

  # Compress consecutive whitespace into single spaces.
  #
  # @param text [String, nil] Text with excessive whitespace
  # @return [String] Text with normalized whitespace
  #
  # @example
  #   compress_whitespace("hello   world\n\nfoo")  # => "hello world foo"
  #
  def compress_whitespace(text)
    return '' if text.nil?

    text.to_s.gsub(/\s+/, ' ').strip
  end
end
