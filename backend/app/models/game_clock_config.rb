# frozen_string_literal: true

# GameClockConfig stores per-universe time configuration.
# Supports realtime (1:1) and accelerated game time modes.
class GameClockConfig < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe

  CLOCK_MODES = %w[realtime accelerated].freeze

  def validate
    super
    validates_presence [:universe_id, :clock_mode]
    validates_includes CLOCK_MODES, :clock_mode
    validates_unique :universe_id

    if clock_mode == 'accelerated'
      errors.add(:time_ratio, 'is required for accelerated mode') if time_ratio.nil?
      errors.add(:game_epoch, 'is required for accelerated mode') if game_epoch.nil?
      errors.add(:real_epoch, 'is required for accelerated mode') if real_epoch.nil?
    end
  end

  # Check if this config uses realtime mode
  # @return [Boolean]
  def realtime?
    clock_mode == 'realtime'
  end

  # Check if this config uses accelerated mode
  # @return [Boolean]
  def accelerated?
    clock_mode == 'accelerated'
  end

  # Start accelerated time mode from now
  # @param ratio [Float] game hours per real hour (default 4.0)
  # @param starting_game_time [Time] when game time "starts" (default: now)
  # @return [GameClockConfig] self
  def start_accelerated_time!(ratio: 4.0, starting_game_time: Time.now)
    update(
      clock_mode: 'accelerated',
      time_ratio: ratio,
      game_epoch: starting_game_time,
      real_epoch: Time.now,
      updated_at: Time.now
    )
    self
  end

  # Switch to realtime mode
  # @return [GameClockConfig] self
  def switch_to_realtime!
    update(
      clock_mode: 'realtime',
      updated_at: Time.now
    )
    self
  end

  # Calculate current game time based on configuration
  # @return [Time] the current game time
  def current_game_time
    if realtime?
      # Just return current time in reference timezone
      Time.now
    else
      # Calculate accelerated time
      return Time.now if game_epoch.nil? || real_epoch.nil?

      real_elapsed = Time.now - real_epoch
      game_elapsed = real_elapsed * time_ratio
      game_epoch + game_elapsed
    end
  end

  # Get dawn hour (from fixed setting or default)
  # @return [Integer] hour of dawn (0-23)
  def dawn_hour
    fixed_dawn_hour || 6
  end

  # Get dusk hour (from fixed setting or default)
  # @return [Integer] hour of dusk (0-23)
  def dusk_hour
    fixed_dusk_hour || 18
  end

  class << self
    # Get or create config for a universe
    # @param universe [Universe] the universe
    # @return [GameClockConfig]
    def for_universe(universe)
      first(universe_id: universe.id) || create_default_for(universe)
    end

    # Create default config for a universe
    # @param universe [Universe] the universe
    # @return [GameClockConfig]
    def create_default_for(universe)
      now = Time.now
      configured_mode = GameSetting.get('default_clock_mode')
      clock_mode = CLOCK_MODES.include?(configured_mode) ? configured_mode : 'realtime'

      time_ratio = GameSetting.float_setting('default_time_ratio')
      time_ratio = 1.0 if time_ratio.nil? || time_ratio <= 0

      attrs = {
        universe_id: universe.id,
        clock_mode: clock_mode,
        time_ratio: time_ratio,
        reference_timezone: GameSetting.get('default_timezone') || 'UTC',
        is_active: true,
        created_at: now,
        updated_at: now
      }

      # Accelerated mode requires both epochs to satisfy model validation.
      if clock_mode == 'accelerated'
        attrs[:game_epoch] = now
        attrs[:real_epoch] = now
      end

      create(attrs)
    end
  end
end
