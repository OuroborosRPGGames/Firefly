# frozen_string_literal: true

# Parses and rolls dice notation like "2d8", "1d6+2", "3d6-1"
# Supports: NdX format with optional +/- modifier
class DiceNotationService
  MIN_SIDES = 1
  MAX_SIDES = 1000
  MIN_COUNT = 1
  MAX_COUNT = 100

  # Roll dice from a notation string
  # @param notation [String] dice notation like "2d8", "1d6+2", "3d6-1"
  # @return [Integer] total roll result
  def self.roll(notation)
    new(notation).roll
  end

  # Parse notation without rolling
  # @param notation [String] dice notation
  # @return [Hash] parsed components { count:, sides:, modifier: }
  def self.parse(notation)
    new(notation).parse
  end

  def initialize(notation)
    # Accept human-friendly spacing like "2d8 + 3"
    @notation = notation.to_s.downcase.gsub(/\s+/, '')
  end

  def roll
    components = parse
    unless components[:valid]
      warn "[DiceNotationService] Invalid notation '#{@notation}': #{components[:error]}"
      return 0
    end

    return components[:modifier] if components[:count] == 0

    total = 0
    components[:count].times do
      total += rand(1..components[:sides])
    end
    total + components[:modifier]
  end

  def parse
    # Match patterns like: "2d8", "1d6+2", "3d6-1", "d20", "5"
    if @notation =~ /^(\d*)d(\d+)([+-]\d+)?$/
      count = ::Regexp.last_match(1).empty? ? 1 : ::Regexp.last_match(1).to_i
      sides = ::Regexp.last_match(2).to_i
      modifier = (::Regexp.last_match(3) || '0').to_i
      return invalid_result("dice count must be between #{MIN_COUNT} and #{MAX_COUNT}") if count < MIN_COUNT || count > MAX_COUNT
      return invalid_result("dice sides must be between #{MIN_SIDES} and #{MAX_SIDES}") if sides < MIN_SIDES || sides > MAX_SIDES

      valid_result(count: count, sides: sides, modifier: modifier)
    elsif @notation =~ /^([+-]?\d+)$/
      # Just a number (flat modifier, no dice)
      valid_result(count: 0, sides: 0, modifier: ::Regexp.last_match(1).to_i)
    else
      invalid_result('notation must match NdX(+/-M), dX, or a flat integer')
    end
  end

  def minimum
    components = parse
    return components[:modifier] unless components[:valid]

    components[:count] + components[:modifier]
  end

  def maximum
    components = parse
    return components[:modifier] unless components[:valid]

    (components[:count] * components[:sides]) + components[:modifier]
  end

  def average
    components = parse
    return components[:modifier].to_f.round(1) unless components[:valid]

    avg_per_die = (1.0 + components[:sides]) / 2.0
    (components[:count] * avg_per_die + components[:modifier]).round(1)
  end

  private

  def valid_result(count:, sides:, modifier:)
    { count: count, sides: sides, modifier: modifier, valid: true, error: nil }
  end

  def invalid_result(error)
    { count: 0, sides: 0, modifier: 0, valid: false, error: error }
  end
end
