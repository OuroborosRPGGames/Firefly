# frozen_string_literal: true

# Provides helper methods for common Sequel query patterns.
#
# This eliminates the repetitive use of Sequel.lit for case-insensitive
# searches and other common query patterns throughout the codebase.
#
# Usage:
#   # In a service or model
#   include QueryHelper
#
#   # Then use the helpers:
#   Room.where(ilike_match(:name, 'town')).first      # Exact (case-insensitive)
#   Room.where(ilike_prefix(:name, 'town')).first     # Starts with
#   Room.where(ilike_contains(:name, 'town')).first   # Contains
#
# Or use the class methods directly:
#   Room.where(QueryHelper.ilike_match(:name, 'town')).first
#
module QueryHelper
  # Case-insensitive exact match
  # @param column [Symbol, String] Column name
  # @param value [String] Value to match (will be lowercased)
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  #
  # @example
  #   Room.where(ilike_match(:name, 'Town Square'))
  #   # => SELECT * FROM rooms WHERE LOWER(name) = 'town square'
  def self.ilike_match(column, value)
    Sequel.lit("LOWER(#{column}) = ?", value.to_s.downcase)
  end

  # Case-insensitive prefix match (starts with)
  # @param column [Symbol, String] Column name
  # @param value [String] Prefix to match (will be lowercased and escaped)
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  #
  # @example
  #   Room.where(ilike_prefix(:name, 'Town'))
  #   # => SELECT * FROM rooms WHERE LOWER(name) LIKE 'town%'
  def self.ilike_prefix(column, value)
    escaped = escape_like(value.to_s.downcase)
    Sequel.lit("LOWER(#{column}) LIKE ?", "#{escaped}%")
  end

  # Case-insensitive contains match
  # @param column [Symbol, String] Column name
  # @param value [String] Substring to match (will be lowercased and escaped)
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  #
  # @example
  #   Room.where(ilike_contains(:name, 'Square'))
  #   # => SELECT * FROM rooms WHERE LOWER(name) LIKE '%square%'
  def self.ilike_contains(column, value)
    escaped = escape_like(value.to_s.downcase)
    Sequel.lit("LOWER(#{column}) LIKE ?", "%#{escaped}%")
  end

  # Case-insensitive suffix match (ends with)
  # @param column [Symbol, String] Column name
  # @param value [String] Suffix to match (will be lowercased and escaped)
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  #
  # @example
  #   Room.where(ilike_suffix(:name, 'Square'))
  #   # => SELECT * FROM rooms WHERE LOWER(name) LIKE '%square'
  def self.ilike_suffix(column, value)
    escaped = escape_like(value.to_s.downcase)
    Sequel.lit("LOWER(#{column}) LIKE ?", "%#{escaped}")
  end

  # Match against concatenated columns (common for full name searches)
  # @param columns [Array<Symbol, String>] Column names to concatenate
  # @param value [String] Value to match
  # @param separator [String] Separator between columns (default: ' ')
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  #
  # @example
  #   Character.where(ilike_concat_match([:forename, :surname], 'John Smith'))
  #   # => SELECT * FROM characters WHERE LOWER(COALESCE(forename, '') || ' ' || COALESCE(surname, '')) = 'john smith'
  def self.ilike_concat_match(columns, value, separator: ' ')
    concat_expr = columns.map { |c| "COALESCE(#{c}, '')" }.join(" || '#{separator}' || ")
    Sequel.lit("LOWER(#{concat_expr}) = ?", value.to_s.downcase)
  end

  # Prefix match against concatenated columns
  # @param columns [Array<Symbol, String>] Column names to concatenate
  # @param value [String] Prefix to match
  # @param separator [String] Separator between columns (default: ' ')
  # @return [Sequel::SQL::Expression] SQL expression for WHERE clause
  def self.ilike_concat_prefix(columns, value, separator: ' ')
    concat_expr = columns.map { |c| "COALESCE(#{c}, '')" }.join(" || '#{separator}' || ")
    escaped = escape_like(value.to_s.downcase)
    Sequel.lit("LOWER(#{concat_expr}) LIKE ?", "#{escaped}%")
  end

  # Escape special LIKE characters (%, _, \)
  # @param value [String] Value to escape
  # @return [String] Escaped value safe for LIKE queries
  def self.escape_like(value)
    value.to_s.gsub('\\', '\\\\').gsub('%', '\\%').gsub('_', '\\_')
  end

  # Instance method versions for including in classes
  def ilike_match(column, value)
    QueryHelper.ilike_match(column, value)
  end

  def ilike_prefix(column, value)
    QueryHelper.ilike_prefix(column, value)
  end

  def ilike_contains(column, value)
    QueryHelper.ilike_contains(column, value)
  end

  def ilike_suffix(column, value)
    QueryHelper.ilike_suffix(column, value)
  end

  def ilike_concat_match(columns, value, separator: ' ')
    QueryHelper.ilike_concat_match(columns, value, separator: separator)
  end

  def ilike_concat_prefix(columns, value, separator: ' ')
    QueryHelper.ilike_concat_prefix(columns, value, separator: separator)
  end

  def escape_like(value)
    QueryHelper.escape_like(value)
  end
end
