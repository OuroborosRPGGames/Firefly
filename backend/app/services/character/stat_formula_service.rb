# frozen_string_literal: true

# Safe formula parser for derived stats.
# Uses tokenization (NOT eval) to safely evaluate stat-based formulas.
#
# Supports:
# - Stat abbreviations: STR, DEX, CON, INT, WIS, CHA, etc.
# - Basic arithmetic: +, -, *, /
# - Parentheses: (STR + DEX) / 2
# - Functions: floor(), ceil()
#
# @example
#   StatFormulaService.evaluate("STR + 5", { "STR" => 14 })
#   # => 19
#
#   StatFormulaService.evaluate("floor((STR + DEX) / 2)", { "STR" => 14, "DEX" => 12 })
#   # => 13
#
class StatFormulaService
  ALLOWED_FUNCTIONS = %w[floor ceil].freeze

  class FormulaError < StandardError; end

  class << self
    # Evaluate a formula with given stat values
    # @param formula [String] the formula string
    # @param stat_values [Hash] stat abbreviations => numeric values
    # @return [Integer, nil] the calculated result or nil on error
    def evaluate(formula, stat_values)
      new(formula, stat_values).evaluate
    rescue FormulaError => e
      warn "[StatFormulaService] Formula error: #{e.message}"
      nil
    end

    # Validate a formula without evaluating
    # @param formula [String] the formula to validate
    # @return [Hash] { valid: Boolean, error: String|nil, stat_references: Array }
    def validate(formula)
      new(formula, {}).validate
    end
  end

  def initialize(formula, stat_values, validate_only: false)
    @formula = formula.to_s.strip
    @stat_values = stat_values.transform_keys { |k| k.to_s.upcase }
    @tokens = []
    @position = 0
    @validate_only = validate_only
  end

  def evaluate
    return 0 if @formula.empty?

    tokenize
    result = parse_expression

    # Check we consumed all tokens
    raise FormulaError, "Unexpected token after expression: #{current_token[:type]}" if current_token

    result.round
  end

  def validate
    return { valid: true, stat_references: [] } if @formula.empty?

    @validate_only = true

    begin
      tokenize
      stat_refs = @tokens.select { |t| t[:type] == :stat }.map { |t| t[:value] }

      # Also try parsing to catch structural errors
      parse_expression
      # Check we consumed all tokens
      raise FormulaError, "Unexpected token: #{current_token[:type]}" if current_token

      { valid: true, stat_references: stat_refs.uniq }
    rescue FormulaError => e
      { valid: false, error: e.message, stat_references: [] }
    end
  end

  private

  def tokenize
    input = @formula.dup

    while input.length.positive?
      input = input.lstrip
      break if input.empty?

      case input
      when /\A(\d+(?:\.\d+)?)/
        # Number (integer or decimal)
        @tokens << { type: :number, value: ::Regexp.last_match(1).to_f }
        input = input[::Regexp.last_match(0).length..]
      when /\A(floor|ceil)\s*\(/i
        # Function call
        func = ::Regexp.last_match(1).downcase
        raise FormulaError, "Unknown function: #{func}" unless ALLOWED_FUNCTIONS.include?(func)

        @tokens << { type: :function, value: func }
        # Remove function name but keep the opening paren
        input = input[::Regexp.last_match(1).length..].lstrip
      when /\A([A-Z]{2,10})/i
        # Stat abbreviation (2-10 letters)
        @tokens << { type: :stat, value: ::Regexp.last_match(1).upcase }
        input = input[::Regexp.last_match(0).length..]
      when /\A([+\-*\/])/
        # Operator
        @tokens << { type: :operator, value: ::Regexp.last_match(1) }
        input = input[1..]
      when /\A\(/
        # Open paren
        @tokens << { type: :lparen }
        input = input[1..]
      when /\A\)/
        # Close paren
        @tokens << { type: :rparen }
        input = input[1..]
      else
        raise FormulaError, "Unexpected character: '#{input[0]}'"
      end
    end
  end

  def current_token
    @tokens[@position]
  end

  def consume(expected_type = nil)
    token = current_token
    if expected_type && token&.[](:type) != expected_type
      raise FormulaError, "Expected #{expected_type}, got #{token&.[](:type) || 'end of formula'}"
    end

    @position += 1
    token
  end

  def peek_type
    current_token&.[](:type)
  end

  # Expression = Additive
  def parse_expression
    parse_additive
  end

  # Additive = Multiplicative (('+' | '-') Multiplicative)*
  def parse_additive
    left = parse_multiplicative

    while current_token && current_token[:type] == :operator && %w[+ -].include?(current_token[:value])
      op = consume[:value]
      right = parse_multiplicative
      left = op == '+' ? left + right : left - right
    end

    left
  end

  # Multiplicative = Primary (('*' | '/') Primary)*
  def parse_multiplicative
    left = parse_primary

    while current_token && current_token[:type] == :operator && %w[* /].include?(current_token[:value])
      op = consume[:value]
      right = parse_primary
      if op == '*'
        left *= right
      else
        raise FormulaError, 'Division by zero' if right.zero?

        left /= right.to_f
      end
    end

    left
  end

  # Primary = Number | Stat | Function '(' Expression ')' | '(' Expression ')'
  def parse_primary
    token = current_token
    raise FormulaError, 'Unexpected end of formula' unless token

    case token[:type]
    when :number
      consume
      token[:value]
    when :stat
      consume
      # In validate mode, return dummy value; in evaluate mode, look up actual value
      if @validate_only
        1.0
      else
        value = @stat_values[token[:value]]
        raise FormulaError, "Unknown stat: #{token[:value]}" if value.nil?

        value.to_f
      end
    when :function
      func = consume[:value]
      consume(:lparen)
      value = parse_expression
      consume(:rparen)
      func == 'floor' ? value.floor : value.ceil
    when :lparen
      consume
      value = parse_expression
      consume(:rparen)
      value
    else
      raise FormulaError, "Unexpected token: #{token[:type]}"
    end
  end
end
