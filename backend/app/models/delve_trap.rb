# frozen_string_literal: true

# DelveTrap represents a timing-based trap blocking movement in a direction.
# Uses two coprime numbers to create a pattern the player must analyze.
# When moving through a trapped direction, player must time their passage.
return unless DB.table_exists?(:delve_traps)

class DelveTrap < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve_room

  DIRECTIONS = %w[north south east west].freeze

  # Era-themed trap types
  THEMES = {
    medieval: %w[wall_crusher spikes pendulum_blade poison_dart arrow_volley],
    gaslight: %w[steam_vent gas_release clockwork_blade pressure_plate tesla_coil],
    modern: %w[laser_grid electrical_surge gas_release motion_turret spike_floor],
    near_future: %w[plasma_burst force_field_pulse nano_swarm stun_field sonic_trap],
    scifi: %w[disintegration_beam gravity_well teleport_trap phase_shift ion_cannon]
  }.freeze

  def validate
    super
    validates_presence [:delve_room_id, :timing_a, :timing_b]
    validates_includes DIRECTIONS, :direction if direction
  end

  def before_save
    super
    self.damage ||= 1
    self.triggered = false if triggered.nil?
    self.disabled = false if disabled.nil?
  end

  # ====== State Checks ======

  def triggered?
    triggered == true
  end

  def disabled?
    disabled == true
  end

  def active?
    !disabled?
  end

  # ====== Timing Logic ======

  # Check if a specific tick is trapped (multiple of either timing number)
  # @param tick [Integer] the tick number to check
  def trapped_at?(tick)
    (tick % timing_a).zero? || (tick % timing_b).zero?
  end

  # Generate a sequence of trap states
  # @param start_tick [Integer] starting tick
  # @param length [Integer] number of ticks to show
  # @return [Array<Hash>] sequence with display number, actual tick, and trapped status
  def generate_sequence(start_tick, length)
    Array.new(length) do |i|
      actual_tick = start_tick + i
      {
        display: i + 1,
        actual: actual_tick,
        trapped: trapped_at?(actual_tick)
      }
    end
  end

  # Check if passage at a given tick is safe
  # @param tick [Integer] the tick the player chose
  # @param experienced [Boolean] true if player has passed this trap before
  # First passage: need chosen tick AND next tick to be safe
  # Experienced: only chosen tick needs to be safe
  def safe_at?(tick, experienced: false)
    if experienced
      # Experienced passage: only the selected beat needs to be safe
      !trapped_at?(tick)
    else
      # First passage: both selected beat AND next beat must be safe
      !trapped_at?(tick) && !trapped_at?(tick + 1)
    end
  end

  # ====== Actions ======

  # Mark trap as triggered (player got hit)
  def trigger!
    update(triggered: true)
  end

  # Disable the trap (somehow neutralized)
  def disable!
    update(disabled: true)
  end

  # ====== Display ======

  def description
    theme_desc = case trap_theme
                 when 'wall_crusher' then 'Walls slam together periodically'
                 when 'spikes' then 'Spikes thrust from the floor'
                 when 'pendulum_blade' then 'A massive blade swings back and forth'
                 when 'poison_dart' then 'Poison darts shoot from the walls'
                 when 'steam_vent' then 'Jets of scalding steam blast intermittently'
                 when 'gas_release' then 'Toxic gas vents at regular intervals'
                 when 'clockwork_blade' then 'Mechanical blades spin in deadly patterns'
                 when 'laser_grid' then 'Lasers sweep across the passage'
                 when 'plasma_burst' then 'Plasma jets fire in sequence'
                 when 'disintegration_beam' then 'A disintegration beam pulses menacingly'
                 else 'A deadly trap blocks the way'
                 end

    "#{theme_desc}. Watch the timing carefully before proceeding."
  end

  # Format sequence for display
  def format_sequence(sequence)
    sequence.map do |s|
      state = s[:trapped] ? 'TRAP!' : 'quiet'
      "#{s[:display]}. #{state}"
    end.join("\n")
  end

  # ====== Class Methods ======

  class << self
    # Generate coprime timing numbers
    # @return [Array<Integer>] two coprime numbers between 3-10
    def generate_timings
      candidates = (3..10).to_a

      # Find two numbers that aren't multiples of each other
      100.times do
        a = candidates.sample
        b = (candidates - [a]).sample

        # Skip if one is a multiple of the other
        next if (a % b).zero? || (b % a).zero?

        # Skip if they share a common factor > 1 (not coprime enough)
        next if a.gcd(b) > 1

        return [a, b].sort
      end

      # Fallback to known good pair
      [3, 7]
    end

    # Get a random theme for an era
    # @param era [Symbol, String] the current game era
    def random_theme(era)
      themes = THEMES[era.to_sym] || THEMES[:modern]
      themes.sample
    end
  end
end
