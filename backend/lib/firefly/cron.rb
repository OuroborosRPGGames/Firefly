# frozen_string_literal: true

module Firefly
  # Cron expression matching for scheduled tasks
  #
  # Uses AresMUSH-style cron specifications with arrays of integers:
  #   { minutes: [0, 30], hours: [3], days: [], weekdays: [] }
  #
  # Empty array means "any value" (wildcard).
  #
  module Cron
    class << self
      # Check if the current time matches a cron spec
      # @param spec [Hash] cron specification
      # @param time [Time] time to check (defaults to now)
      # @return [Boolean]
      def matches?(spec, time = Time.now)
        matches_minute?(spec, time) &&
          matches_hour?(spec, time) &&
          matches_day?(spec, time) &&
          matches_weekday?(spec, time)
      end

      # Calculate the next occurrence of a cron spec
      # @param spec [Hash] cron specification
      # @param from [Time] start time (defaults to now)
      # @return [Time]
      def next_occurrence(spec, from = Time.now)
        # Start from the next minute
        candidate = Time.new(from.year, from.month, from.day, from.hour, from.min) + 60

        # Search up to a year in the future
        max_iterations = 525_600 # minutes in a year
        max_iterations.times do
          return candidate if matches?(spec, candidate)
          candidate += 60
        end

        # Fallback: next hour
        from + 3600
      end

      # Parse a human-readable cron string into spec hash
      # @param str [String] e.g., "every hour", "daily at 3am", "0 3 * * *"
      # @return [Hash]
      def parse(str)
        case str.downcase.strip
        when 'every minute', 'minutely'
          { minutes: [], hours: [], days: [], weekdays: [] }
        when 'every hour', 'hourly'
          { minutes: [0], hours: [], days: [], weekdays: [] }
        when 'every day', 'daily'
          { minutes: [0], hours: [0], days: [], weekdays: [] }
        when /daily at (\d+)(am|pm)?/i
          hour = Regexp.last_match(1).to_i
          hour += 12 if Regexp.last_match(2)&.downcase == 'pm' && hour < 12
          { minutes: [0], hours: [hour], days: [], weekdays: [] }
        when 'every week', 'weekly'
          { minutes: [0], hours: [0], days: [], weekdays: [0] } # Sunday
        when 'every month', 'monthly'
          { minutes: [0], hours: [0], days: [1], weekdays: [] }
        when /^(\d+)\s+(\d+|\*)\s+(\d+|\*)\s+(\*|\d+)\s+(\*|\d+)$/
          # Standard cron format: minute hour day month weekday
          # We don't use month, but parse it anyway
          parse_cron_format(str)
        else
          # Default to hourly
          { minutes: [0], hours: [], days: [], weekdays: [] }
        end
      end

      private

      def matches_minute?(spec, time)
        minutes = spec[:minutes] || []
        return true if minutes.empty?
        minutes.include?(time.min)
      end

      def matches_hour?(spec, time)
        hours = spec[:hours] || []
        return true if hours.empty?
        hours.include?(time.hour)
      end

      def matches_day?(spec, time)
        days = spec[:days] || []
        return true if days.empty?
        days.include?(time.day)
      end

      def matches_weekday?(spec, time)
        weekdays = spec[:weekdays] || []
        return true if weekdays.empty?
        weekdays.include?(time.wday)
      end

      def parse_cron_format(str)
        parts = str.split
        {
          minutes: parse_cron_field(parts[0], 0..59),
          hours: parse_cron_field(parts[1], 0..23),
          days: parse_cron_field(parts[2], 1..31),
          weekdays: parse_cron_field(parts[4], 0..6)
        }
      end

      def parse_cron_field(field, _range)
        return [] if field == '*'
        return [field.to_i] if field =~ /^\d+$/
        []
      end
    end
  end
end
