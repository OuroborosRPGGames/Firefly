# frozen_string_literal: true

# Provides a DSL for defining status enums on Sequel models.
#
# This concern eliminates the repetitive pattern of:
#   STATUSES = %w[pending completed failed].freeze
#   validates_includes STATUSES, :status
#
# And adds convenient query and scope methods.
#
# Usage:
#   class MyModel < Sequel::Model
#     include StatusEnum
#
#     status_enum :status, %w[pending processing completed failed]
#     # Or with a custom column name:
#     status_enum :delivery_status, %w[pending in_transit delivered]
#   end
#
# This generates:
#   - STATUSES constant (or DELIVERY_STATUSES for custom columns)
#   - Validation: validates_includes STATUSES, :status
#   - Query methods: pending?, processing?, completed?, failed?
#   - Scope methods: Model.pending, Model.completed, etc.
#   - Transition check: can_transition_to?(:completed)
#
module StatusEnum
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    # Define a status enum on the model.
    #
    # @param column [Symbol] the column name (default: :status)
    # @param values [Array<String>] the valid status values
    # @param prefix [Boolean, String] prefix for query methods (default: false)
    # @param validate [Boolean] whether to add validation (default: true)
    # @param scopes [Boolean] whether to add scope methods (default: true)
    #
    # @example Basic usage
    #   status_enum :status, %w[pending completed failed]
    #
    # @example With custom column
    #   status_enum :delivery_status, %w[pending in_transit delivered]
    #
    # @example With prefix to avoid method conflicts
    #   status_enum :status, %w[active inactive], prefix: true
    #   # Generates: status_active?, status_inactive?
    #
    def status_enum(column = :status, values = [], prefix: false, validate: true, scopes: true)
      # Create the constant (e.g., :status → STATUSES, :mount_status → MOUNT_STATUSES)
      col_str = column.to_s.upcase
      const_name = if col_str.end_with?('_STATUS')
                     "#{col_str.sub(/_STATUS$/, '')}_STATUSES"
                   elsif col_str.end_with?('S')
                     "#{col_str}ES"
                   else
                     "#{col_str}S"
                   end
      const_set(const_name, values.map(&:to_s).freeze) unless const_defined?(const_name)

      statuses = const_get(const_name)

      # Add validation
      if validate
        define_method("validate_#{column}_enum") do
          # Access value through Sequel's standard accessor
          val = begin
            self[column]
          rescue StandardError => e
            warn "[StatusEnum] Column access failed for #{column}: #{e.message}"
            nil
          end
          if val && !statuses.include?(val.to_s)
            errors.add(column, "must be one of: #{statuses.join(', ')}")
          end
        end

        # Hook into Sequel's validation
        if respond_to?(:plugin)
          plugin :validation_helpers unless plugins.include?(Sequel::Plugins::ValidationHelpers)
        end

        # Define a validation method that gets called
        define_method(:validate_status_enums) do
          send("validate_#{column}_enum")
        end

        # Store which columns have status enums for validation
        @status_enum_columns ||= []
        @status_enum_columns << column

        class_eval do
          def validate
            super
            self.class.status_enum_columns.each do |col|
              send("validate_#{col}_enum")
            end
          end

          def self.status_enum_columns
            @status_enum_columns ||= []
          end
        end
      end

      # Generate query methods (e.g., pending?, completed?)
      statuses.each do |status|
        method_name = if prefix == true
                        "#{column}_#{status}?"
                      elsif prefix
                        "#{prefix}_#{status}?"
                      else
                        "#{status}?"
                      end

        define_method(method_name) do
          # Use Sequel's standard accessor
          val = begin
            self[column]
          rescue StandardError => e
            warn "[StatusEnum] Column access failed for #{column}: #{e.message}"
            nil
          end
          val.to_s == status.to_s
        end
      end

      # Generate scope methods (e.g., Model.pending, Model.completed)
      return unless scopes

      statuses.each do |status|
        scope_name = if prefix == true
                       "#{column}_#{status}"
                     elsif prefix
                       "#{prefix}_#{status}"
                     else
                       status
                     end

        # Use dataset_module for Sequel scopes
        dataset_module do
          define_method(scope_name) do
            where(column => status)
          end
        end
      end
    end

    # Check if a value is a valid status for the column.
    #
    # @param column [Symbol] the column name
    # @param value [String, Symbol] the value to check
    # @return [Boolean]
    def valid_status?(column, value)
      col_str = column.to_s.upcase
      const_name = if col_str.end_with?('_STATUS')
                     "#{col_str.sub(/_STATUS$/, '')}_STATUSES"
                   elsif col_str.end_with?('S')
                     "#{col_str}ES"
                   else
                     "#{col_str}S"
                   end
      return false unless const_defined?(const_name)

      const_get(const_name).include?(value.to_s)
    end
  end

  # Check if the current status can transition to a new status.
  # Override this method in your model to define valid transitions.
  #
  # @param new_status [String, Symbol] the target status
  # @param column [Symbol] the column name (default: :status)
  # @return [Boolean] true if transition is allowed
  def can_transition_to?(new_status, column: :status)
    # Default: any transition is allowed
    # Override in model for specific transition rules
    self.class.valid_status?(column, new_status)
  end

  # Transition to a new status, with optional validation.
  #
  # @param new_status [String, Symbol] the target status
  # @param column [Symbol] the column name (default: :status)
  # @param validate [Boolean] whether to check can_transition_to?
  # @return [Boolean] true if transition succeeded
  def transition_to!(new_status, column: :status, validate: true)
    if validate && !can_transition_to?(new_status, column: column)
      raise ArgumentError, "Cannot transition from #{send(column)} to #{new_status}"
    end

    update(column => new_status.to_s)
  end
end
