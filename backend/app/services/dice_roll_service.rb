# frozen_string_literal: true

# Service for dice rolling with exploding dice support and animation data generation.
# Generates Ravencroft-style animation data for the webclient.
#
# This is the primary dice rolling service. For notation-based rolling (e.g., "2d8+2"),
# use DiceNotationService which delegates to this service.
class DiceRollService
  # Result structure for dice rolls
  RollResult = Struct.new(
    :dice,          # Array of individual die results (including explosions)
    :base_dice,     # Array of original dice before explosions
    :explosions,    # Array of indices where explosions occurred
    :modifier,      # Stat modifier applied
    :total,         # Final total (sum of dice + modifier)
    :count,         # Number of dice rolled
    :sides,         # Number of sides per die
    :explode_on,    # Value that triggers explosion (nil if no exploding)
    keyword_init: true
  ) do
    # Get the minimum possible roll (each die = 1)
    def minimum
      count + modifier
    end

    # Get the maximum possible roll (each die = max, no explosions counted)
    def maximum
      (count * sides) + modifier
    end

    # Get the average roll
    def average
      avg_per_die = (1.0 + sides) / 2.0
      (count * avg_per_die + modifier).round(1)
    end
  end

  # Roll dice with optional exploding
  # @param count [Integer] Number of dice to roll
  # @param sides [Integer] Number of sides per die
  # @param explode_on [Integer, nil] Value that triggers explosion (nil for no exploding)
  # @param modifier [Integer] Modifier to add to total
  # @param max_explosions [Integer] Maximum explosions per die (prevents infinite loops)
  # @return [RollResult]
  def self.roll(count, sides, explode_on: nil, modifier: 0, max_explosions: nil)
    limits = GameConfig::Dice::SERVICE_LIMITS
    max_explosions ||= limits[:max_explosions]
    raise ArgumentError, "Count must be #{limits[:count_range]}" unless limits[:count_range].cover?(count)
    raise ArgumentError, "Sides must be #{limits[:sides_range]}" unless limits[:sides_range].cover?(sides)

    base_dice = []
    all_dice = []
    explosions = []

    count.times do |die_index|
      result = rand(1..sides)
      base_dice << result
      all_dice << result

      # Handle exploding dice
      if explode_on && result == explode_on
        explosion_count = 0
        while result == explode_on && explosion_count < max_explosions
          explosions << all_dice.length - 1
          result = rand(1..sides)
          all_dice << result
          explosion_count += 1
        end
      end
    end

    total = all_dice.sum + modifier

    RollResult.new(
      dice: all_dice,
      base_dice: base_dice,
      explosions: explosions,
      modifier: modifier,
      total: total,
      count: count,
      sides: sides,
      explode_on: explode_on
    )
  end

  # Roll 2d8 with exploding 8s (standard stat roll)
  # @param modifier [Integer] Stat modifier to add
  # @return [RollResult]
  def self.roll_2d8_exploding(modifier = 0)
    roll(2, 8, explode_on: 8, modifier: modifier)
  end

  # Generate animation data for the webclient
  # Format: character_name|||color|||die1_data(())die2_data...
  # Die data: dtype||delay||result||roll1|roll2|roll3|roll4
  #
  # @param roll_result [RollResult] The roll result
  # @param character_name [String] Name of the character rolling
  # @param color [String] Color code (w=white, g=green, r=red, c=cyan)
  # @return [String] Animation data string
  def self.generate_animation_data(roll_result, character_name:, color: 'w')
    dice_parts = []
    explosion_tracker = roll_result.explosions.dup
    anim = GameConfig::Dice::ANIMATION

    # Pre-generate random frame counts for base dice so we know when they all settle
    base_frame_counts = Array.new(roll_result.count) { rand(anim[:base_frames]) }
    max_base_frames = base_frame_counts.max || 0

    # Track cumulative delay for staggering explosion dice
    explosion_delay = max_base_frames

    roll_result.dice.each_with_index do |die_result, idx|
      # Determine die type for coloring
      # dtype: 0=normal (white), 1=success (green), 2=critical/explosion (cyan), 3=fail (red)
      dtype = if explosion_tracker.include?(idx)
                2 # Explosion source - cyan
              elsif die_result == roll_result.sides
                1 # Max roll - green
              elsif die_result == 1
                3 # Min roll - red
              else
                0 # Normal - white
              end

      is_explosion_die = idx >= roll_result.count

      if is_explosion_die
        seq_length = rand(anim[:explosion_frames])
        delay = explosion_delay
        explosion_delay += seq_length # next explosion starts after this one settles
      else
        seq_length = base_frame_counts[idx]
        delay = 0
      end

      roll_sequence = generate_roll_sequence(die_result, roll_result.sides, length: seq_length)
      dice_parts << "#{dtype}||#{delay}||#{die_result}||#{roll_sequence.join('|')}"
    end

    "#{character_name}|||#{color}|||#{dice_parts.join('(())')}"
  end

  # Calculate the total animation duration in milliseconds from an animation data string.
  # Mirrors the client-side DiceAnimator.animate() timing logic:
  #   maxFrames = max(delay + rolls.length) across all dice
  #   duration = ((maxFrames - 1) * 800) + 1600
  # @param animation_data [String] Animation data string (name|||color|||die1(())die2...)
  # @return [Integer] Duration in milliseconds
  def self.calculate_animation_duration_ms(animation_data)
    return 3000 if animation_data.nil? || animation_data.empty?

    # Strip name|||color||| prefix — dice data starts after third |||
    parts = animation_data.split('|||', 3)
    dice_str = parts[2] || parts[0]

    # Each die is separated by (())
    dice_parts = dice_str.split('(())')

    max_frames = dice_parts.map do |part|
      # Format: dtype||delay||result||roll1|roll2|roll3|roll4
      fields = part.split('||')
      delay = (fields[1] || '0').to_i
      rolls_count = fields[3] ? fields[3].split('|').length : 4
      delay + rolls_count
    end.max || 4

    # Match client: (maxFrames - 1) * 800ms per frame + 1600ms for final reveal
    ((max_frames - 1) * 800) + 1600
  end

  # Generate a random sequence for dice animation
  # @param final_value [Integer] The final landed value
  # @param sides [Integer] Number of sides on the die
  # @param length [Integer] Number of animation frames
  # @return [Array<Integer>]
  def self.generate_roll_sequence(final_value, sides, length: nil)
    length ||= rand(GameConfig::Dice::ANIMATION[:base_frames])
    sequence = Array.new(length - 1) { rand(1..sides) }
    sequence << final_value
    sequence
  end

  # Format roll result as readable text
  # @param roll_result [RollResult] The roll result
  # @param stat_names [Array<String>] Names of stats used (optional)
  # @return [String]
  def self.format_roll_text(roll_result, stat_names: nil)
    parts = []

    # Describe the roll
    dice_desc = "#{roll_result.count}d#{roll_result.sides}"
    dice_desc += " (exploding on #{roll_result.explode_on}s)" if roll_result.explode_on

    parts << "Rolling #{dice_desc}"
    parts << "Stats: #{stat_names.join(' + ')}" if stat_names&.any?

    # Show dice results
    dice_str = roll_result.dice.map.with_index do |d, i|
      if roll_result.explosions.include?(i)
        "[#{d}!]" # Mark explosion source
      else
        d.to_s
      end
    end.join(' + ')

    parts << "Dice: #{dice_str}"
    parts << "Modifier: +#{roll_result.modifier}" if roll_result.modifier > 0
    parts << "Modifier: #{roll_result.modifier}" if roll_result.modifier < 0
    parts << "Total: #{roll_result.total}"

    parts.join(' | ')
  end

  # Create a simple roll description for broadcasting
  def self.describe_roll(roll_result, character_name:, stat_names: nil)
    dice_results = roll_result.dice.join(', ')
    explosion_note = roll_result.explosions.any? ? ' (exploding!)' : ''

    if stat_names&.any?
      "#{character_name} rolls #{stat_names.join('+')}#{explosion_note}: [#{dice_results}] + #{roll_result.modifier} = #{roll_result.total}"
    else
      "#{character_name} rolls #{roll_result.count}d#{roll_result.sides}#{explosion_note}: [#{dice_results}] = #{roll_result.total}"
    end
  end

  # Parse dice notation (e.g., "2d6", "1d20", "3d8")
  # @param notation [String] Dice notation
  # @return [Hash, nil] { count:, sides: } or nil if invalid
  def self.parse_dice_notation(notation)
    match = notation.to_s.strip.match(/^(\d+)d(\d+)$/i)
    return nil unless match

    limits = GameConfig::Dice::SERVICE_LIMITS
    count = match[1].to_i
    sides = match[2].to_i

    return nil unless limits[:count_range].cover?(count) && limits[:sides_range].cover?(sides)

    { count: count, sides: sides }
  end

  # Parse extended dice notation including modifiers (e.g., "2d8", "1d6+2", "3d6-1", "d20", "5")
  # @param notation [String] Dice notation
  # @return [Hash] { count:, sides:, modifier: }
  def self.parse_notation(notation)
    clean = notation.to_s.strip.downcase

    # Match patterns like: "2d8", "1d6+2", "3d6-1", "d20"
    if clean =~ /^(\d*)d(\d+)([+-]\d+)?$/
      count = ::Regexp.last_match(1).empty? ? 1 : ::Regexp.last_match(1).to_i
      sides = ::Regexp.last_match(2).to_i
      modifier = (::Regexp.last_match(3) || '0').to_i

      { count: count, sides: sides, modifier: modifier }
    elsif clean =~ /^([+-]?\d+)$/
      # Just a number (flat modifier, no dice)
      { count: 0, sides: 0, modifier: ::Regexp.last_match(1).to_i }
    else
      # Invalid notation, default to 0
      { count: 0, sides: 0, modifier: 0 }
    end
  end

  # Roll dice from a notation string (e.g., "2d8", "1d6+2")
  # @param notation [String] Dice notation
  # @param explode_on [Integer, nil] Value that triggers explosion
  # @return [RollResult]
  def self.roll_notation(notation, explode_on: nil)
    parsed = parse_notation(notation)

    return RollResult.new(
      dice: [],
      base_dice: [],
      explosions: [],
      modifier: parsed[:modifier],
      total: parsed[:modifier],
      count: 0,
      sides: 0,
      explode_on: nil
    ) if parsed[:count] == 0

    roll(parsed[:count], parsed[:sides], explode_on: explode_on, modifier: parsed[:modifier])
  end

  # Calculate minimum for a dice notation without rolling
  # @param notation [String] Dice notation
  # @return [Integer]
  def self.notation_minimum(notation)
    parsed = parse_notation(notation)
    parsed[:count] + parsed[:modifier]
  end

  # Calculate maximum for a dice notation without rolling
  # @param notation [String] Dice notation
  # @return [Integer]
  def self.notation_maximum(notation)
    parsed = parse_notation(notation)
    (parsed[:count] * parsed[:sides]) + parsed[:modifier]
  end

  # Calculate average for a dice notation without rolling
  # @param notation [String] Dice notation
  # @return [Float]
  def self.notation_average(notation)
    parsed = parse_notation(notation)
    return parsed[:modifier].to_f if parsed[:count] == 0

    avg_per_die = (1.0 + parsed[:sides]) / 2.0
    (parsed[:count] * avg_per_die + parsed[:modifier]).round(1)
  end
end
