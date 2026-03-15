# frozen_string_literal: true

# Generates time-based color gradients like Ravencroft's daytime_prompt()
# Returns gradient colors that shift based on time of day:
# - Dawn: Orange to Cyan
# - Morning: Yellow to Cyan
# - Noon: Cyan to Yellow (brightest)
# - Afternoon: Cyan to Yellow
# - Dusk: Cyan to Orange
# - Night: Gray (no gradient)
class TimeGradientService
  COLORS = {
    dawn:      { start: '#E94D23', end: '#7DB2B4' },  # Orange to Cyan
    morning:   { start: '#FBF492', end: '#57C8CF' },  # Yellow to Cyan
    noon:      { start: '#57C8CF', end: '#F4FB92' },  # Cyan to Yellow
    afternoon: { start: '#57C8CF', end: '#FBF492' },  # Cyan to Yellow
    dusk:      { start: '#7DB2B4', end: '#E94D23' },  # Cyan to Orange
    night:     { start: '#666666', end: '#666666' }   # Gray (no gradient)
  }.freeze

  DEFAULT_DAWN_HOUR = GameConfig::Time::DEFAULT_DAWN_HOUR
  DEFAULT_DUSK_HOUR = GameConfig::Time::DEFAULT_DUSK_HOUR

  class << self
    # Get gradient colors for the current time
    # @param location [Location, nil] optional location for time calculation
    # @return [Hash] with :period, :start_color, :end_color, :hour
    def gradient_for_time(location = nil)
      hour = current_hour(location)
      period = time_period(hour, location)

      colors = COLORS[period] || COLORS[:noon]
      {
        period: period,
        start_color: colors[:start],
        end_color: colors[:end],
        hour: hour
      }
    end

    # Determine time period from hour
    # @param hour [Integer] 0-23
    # @param location [Location, nil] optional location for dawn/dusk hours
    # @return [Symbol] :dawn, :morning, :noon, :afternoon, :dusk, or :night
    def time_period(hour, location = nil)
      dawn = dawn_hour(location)
      dusk = dusk_hour(location)

      case hour
      when dawn
        :dawn
      when (dawn + 1)..11
        :morning
      when 12
        :noon
      when 13..(dusk - 1)
        :afternoon
      when dusk
        :dusk
      else
        :night
      end
    end

    # Get all colors for reference
    def all_colors
      COLORS
    end

    private

    def current_hour(location)
      GameTimeService.current_time(location).hour
    rescue StandardError => e
      warn "[TimeGradientService] Current hour error: #{e.message}" if ENV['DEBUG']
      Time.now.hour
    end

    def dawn_hour(location)
      # Could be extended to support location-specific dawn hours
      # For now, use default
      DEFAULT_DAWN_HOUR
    end

    def dusk_hour(location)
      # Could be extended to support location-specific dusk hours
      # For now, use default
      DEFAULT_DUSK_HOUR
    end
  end
end
