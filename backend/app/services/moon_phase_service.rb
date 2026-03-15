# frozen_string_literal: true

# MoonPhaseService calculates lunar phases.
# Uses astronomical calculations based on synodic month.
class MoonPhaseService
  # Synodic month (new moon to new moon) in days
  LUNAR_CYCLE_DAYS = 29.53059

  # Reference new moon (known astronomical event)
  KNOWN_NEW_MOON = Time.utc(2000, 1, 6, 18, 14, 0)

  # Moon phase data
  MoonPhase = Struct.new(:name, :emoji, :illumination, :waxing, :cycle_position, keyword_init: true)

  class << self
    # Get current moon phase
    # @param date [Date, Time, nil] the date (default: today)
    # @return [MoonPhase] structured phase data
    def current_phase(date = nil)
      date ||= Date.today
      date = date.to_date if date.respond_to?(:to_date)

      calculate_phase(date)
    end

    # Get moon phase emoji
    # @param date [Date, Time, nil] the date
    # @return [String] moon emoji
    def emoji(date = nil)
      current_phase(date).emoji
    end

    # Get moon phase name
    # @param date [Date, Time, nil] the date
    # @return [String] phase name (e.g., "full moon", "waxing crescent")
    def phase_name(date = nil)
      current_phase(date).name
    end

    # Get illumination percentage (0.0 to 1.0)
    # @param date [Date, Time, nil] the date
    # @return [Float] 0.0 (new moon) to 1.0 (full moon)
    def illumination(date = nil)
      current_phase(date).illumination
    end

    # Check if moon is waxing (getting brighter)
    # @param date [Date, Time, nil] the date
    # @return [Boolean]
    def waxing?(date = nil)
      current_phase(date).waxing
    end

    # Check if moon is waning (getting dimmer)
    # @param date [Date, Time, nil] the date
    # @return [Boolean]
    def waning?(date = nil)
      !current_phase(date).waxing
    end

    # Check if tonight is a full moon (within 1 day)
    # @param date [Date, Time, nil] the date
    # @return [Boolean]
    def full_moon?(date = nil)
      phase = current_phase(date)
      phase.illumination >= 0.95
    end

    # Check if tonight is a new moon (within 1 day)
    # @param date [Date, Time, nil] the date
    # @return [Boolean]
    def new_moon?(date = nil)
      phase = current_phase(date)
      phase.illumination <= 0.05
    end

    # Get a description of the moon's current state
    # @param date [Date, Time, nil] the date
    # @return [String]
    def description(date = nil)
      phase = current_phase(date)
      direction = phase.waxing ? 'waxing' : 'waning'
      illumination_pct = (phase.illumination * 100).round

      if phase.name.include?('full') || phase.name.include?('new')
        "The #{phase.name} hangs in the sky"
      else
        "A #{phase.name} (#{illumination_pct}% illuminated, #{direction})"
      end
    end

    private

    # Calculate moon phase for a given date
    # @param date [Date] the date
    # @return [MoonPhase]
    def calculate_phase(date)
      # Days since known new moon
      days_since = (date.to_time - KNOWN_NEW_MOON) / (24 * 60 * 60)

      # Position in current cycle (0.0 to 1.0)
      cycle_position = (days_since % LUNAR_CYCLE_DAYS) / LUNAR_CYCLE_DAYS

      # Waxing = first half of cycle (0.0 to 0.5)
      waxing = cycle_position <= 0.5

      # Calculate illumination (0 at new moon, 1 at full, 0 at new again)
      illumination = if waxing
                       cycle_position * 2
                     else
                       (1.0 - cycle_position) * 2
                     end

      # Determine phase name and emoji
      phase_data = determine_phase(illumination, waxing)

      MoonPhase.new(
        name: phase_data[:name],
        emoji: phase_data[:emoji],
        illumination: illumination.round(3),
        waxing: waxing,
        cycle_position: cycle_position.round(3)
      )
    end

    # Determine phase name and emoji from illumination
    # @param illumination [Float] 0.0 to 1.0
    # @param waxing [Boolean] true if waxing
    # @return [Hash] { name: String, emoji: String }
    def determine_phase(illumination, waxing)
      if illumination <= 0.05
        { name: 'new moon', emoji: "\u{1F311}" }
      elsif illumination <= 0.25
        if waxing
          { name: 'waxing crescent', emoji: "\u{1F312}" }
        else
          { name: 'waning crescent', emoji: "\u{1F318}" }
        end
      elsif illumination <= 0.55
        if waxing
          { name: 'first quarter', emoji: "\u{1F313}" }
        else
          { name: 'last quarter', emoji: "\u{1F317}" }
        end
      elsif illumination <= 0.95
        if waxing
          { name: 'waxing gibbous', emoji: "\u{1F314}" }
        else
          { name: 'waning gibbous', emoji: "\u{1F316}" }
        end
      else
        { name: 'full moon', emoji: "\u{1F315}" }
      end
    end
  end
end
