# frozen_string_literal: true

# Provides DSL for defining boolean predicate methods on models.
#
# Usage:
#   class MyModel < Sequel::Model
#     include BooleanHelpers
#
#     boolean_predicate :private_mode     # Creates private_mode? method
#     boolean_predicate :staff_only       # Creates staff_only? method
#     boolean_predicate :invisible, :hidden  # Creates invisible? and hidden? aliases
#   end
#
module BooleanHelpers
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    # Define a boolean predicate method for a column
    #
    # @param field_name [Symbol] The database column name
    # @param aliases [Array<Symbol>] Additional method names that should work the same way
    #
    # Example:
    #   boolean_predicate :staff_only
    #   # => defines staff_only? that returns self[:staff_only] == true
    #
    #   boolean_predicate :invisible, :hidden
    #   # => defines invisible? and hidden? that both check :invisible column
    #
    def boolean_predicate(field_name, *aliases)
      # Define the main predicate method
      define_method("#{field_name}?") do
        self[field_name] == true
      end

      # Define alias methods
      aliases.each do |alias_name|
        define_method("#{alias_name}?") do
          self[field_name] == true
        end
      end
    end

    # Define toggle methods for a boolean field
    #
    # @param field_name [Symbol] The database column name
    #
    # Example:
    #   boolean_toggle :private_mode
    #   # => defines:
    #   #    toggle_private_mode!
    #   #    enable_private_mode!
    #   #    disable_private_mode!
    #
    def boolean_toggle(field_name)
      # Ensure predicate method exists
      boolean_predicate(field_name) unless method_defined?("#{field_name}?")

      # Toggle method
      define_method("toggle_#{field_name}!") do
        update(field_name => !send("#{field_name}?"))
      end

      # Enable method
      define_method("enable_#{field_name}!") do
        update(field_name => true)
      end

      # Disable method
      define_method("disable_#{field_name}!") do
        update(field_name => false)
      end
    end
  end
end
