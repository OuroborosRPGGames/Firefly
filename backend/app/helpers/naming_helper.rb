# frozen_string_literal: true

# Provides naming convention helpers that replace Rails' ActiveSupport methods.
#
# This is a pure Ruby implementation since Firefly uses Sequel, not Rails.
# These methods replace the common Rails patterns: .underscore, .demodulize
#
# Usage:
#   # As instance method (when included):
#   class MyService
#     include NamingHelper
#
#     def process(klass)
#       table_name = to_snake_case(klass.name)
#       # ...
#     end
#   end
#
#   # As module method (for class-level or standalone use):
#   NamingHelper.to_snake_case('MyClassName')  # => 'my_class_name'
#   NamingHelper.class_to_snake_case('Commands::Wave')  # => 'wave'
#
module NamingHelper
  module_function
  # Convert a CamelCase string to snake_case (like Rails' underscore)
  #
  # @param str [String] The CamelCase string to convert
  # @return [String] The snake_case version
  #
  # @example
  #   to_snake_case('MyClassName')        # => 'my_class_name'
  #   to_snake_case('API')                # => 'api'
  #   to_snake_case('HTTPRequest')        # => 'http_request'
  #   to_snake_case('Module::ClassName')  # => 'module::class_name'
  def to_snake_case(str)
    str.to_s
       .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
       .gsub(/([a-z\d])([A-Z])/, '\1_\2')
       .downcase
  end

  # Get the class name without module namespace (like Rails' demodulize)
  #
  # @param str [String] The fully qualified class name
  # @return [String] Just the class name without namespace
  #
  # @example
  #   demodulize('Commands::Social::Wave')  # => 'Wave'
  #   demodulize('MyClass')                  # => 'MyClass'
  def demodulize(str)
    str.to_s.split('::').last || str.to_s
  end

  # Convert a class name to snake_case, removing module namespace
  # Combines demodulize + underscore (common Rails pattern)
  #
  # @param str [String] The fully qualified class name
  # @return [String] The snake_case class name without namespace
  #
  # @example
  #   class_to_snake_case('Commands::Social::Wave')  # => 'wave'
  #   class_to_snake_case('MyClassName')             # => 'my_class_name'
  def class_to_snake_case(str)
    to_snake_case(demodulize(str))
  end

  # Convert an object's class to snake_case
  # Shorthand for class_to_snake_case(obj.class.name)
  #
  # @param obj [Object] Any object
  # @return [String] The object's class name in snake_case
  #
  # @example
  #   underscore_class_name(User.new)        # => 'user'
  #   underscore_class_name(FightService.new) # => 'fight_service'
  def underscore_class_name(obj)
    class_to_snake_case(obj.class.name)
  end

  # Convert snake_case or underscore_separated to Title Case (like Rails' titleize)
  #
  # @param str [String] The string to titleize
  # @return [String] The Title Case version
  #
  # @example
  #   titleize('my_class_name')   # => 'My Class Name'
  #   titleize('street')          # => 'Street'
  #   titleize('foo_bar_baz')     # => 'Foo Bar Baz'
  def titleize(str)
    str.to_s.tr('_', ' ').gsub(/\b\w/) { |c| c.upcase }
  end

  # Convert snake_case to human-readable sentence case (like Rails' humanize)
  #
  # @param str [String] The string to humanize
  # @return [String] The humanized version (only first word capitalized)
  #
  # @example
  #   humanize('my_class_name')   # => 'My class name'
  #   humanize('street')          # => 'Street'
  #   humanize('foo_bar_baz')     # => 'Foo bar baz'
  def humanize(str)
    result = str.to_s.tr('_', ' ')
    result[0] = result[0].upcase if result.length > 0
    result
  end
end
