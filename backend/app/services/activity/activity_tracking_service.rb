# frozen_string_literal: true

# Service for tracking and analyzing character activity patterns.
#
# Usage:
#   ActivityTrackingService.record_active_characters!  # Called by scheduler
#   ActivityTrackingService.calculate_overlap(char_a, char_b)
#   ActivityTrackingService.find_meeting_times([char1, char2, char3])
#
class ActivityTrackingService
  # Minimum activity score to consider "likely available"
  DEFAULT_THRESHOLD = GameConfig::Timeouts::ACTIVITY_DEFAULT_THRESHOLD

  # Minutes of inactivity before considering character idle
  ACTIVITY_TIMEOUT_MINUTES = GameConfig::Timeouts::ACTIVITY_TIMEOUT_MINUTES

  class << self
    # ===== Scheduled Tasks =====

    # Record activity samples for all online+active characters
    # Called by scheduler every 5 minutes
    def record_active_characters!
      recorded = 0
      skipped = 0

      # Find online characters with recent activity (within 15 min) using dataset scope
      CharacterInstance.active(minutes_ago: ACTIVITY_TIMEOUT_MINUTES).each do |ci|
        begin
          profile = ActivityProfile.for_character(ci.character)
          next unless profile.tracking_enabled

          profile.record_sample!
          recorded += 1
        rescue StandardError => e
          warn "[ActivityTracking] Error recording for character #{ci.character_id}: #{e.message}"
          skipped += 1
        end
      end

      { recorded: recorded, skipped: skipped }
    end

    # Apply decay to all profiles (run weekly)
    def apply_decay_to_all!
      decayed = 0

      ActivityProfile.where(tracking_enabled: true).each do |profile|
        begin
          profile.apply_decay!
          decayed += 1
        rescue StandardError => e
          warn "[ActivityTracking] Error applying decay for profile #{profile.id}: #{e.message}"
        end
      end

      { decayed: decayed }
    end

    # ===== Overlap Calculation =====

    # Calculate overlap between two characters
    # @param char_a [Character]
    # @param char_b [Character]
    # @param threshold [Integer]
    # @return [Hash] { percentage:, best_days:, best_times:, summary: }
    def calculate_overlap(char_a, char_b, threshold: DEFAULT_THRESHOLD)
      profile_a = ActivityProfile.for_character(char_a)
      profile_b = ActivityProfile.for_character(char_b)

      # Check if both share their schedules
      unless profile_a.share_schedule && profile_b.share_schedule
        return { error: 'One or both characters have schedule sharing disabled' }
      end

      # Check for sufficient data
      unless profile_a.has_sufficient_data? && profile_b.has_sufficient_data?
        return { error: 'Not enough activity data yet', insufficient_data: true }
      end

      percentage = profile_a.overlap_with(profile_b, threshold: threshold)
      best_days = profile_a.best_overlap_days(profile_b, threshold: threshold)
      best_times = profile_a.best_overlap_times(profile_b, limit: 3, threshold: threshold)

      # Build human-readable summary
      summary = build_overlap_summary(percentage, best_days)

      {
        percentage: percentage,
        best_days: best_days,
        best_times: best_times,
        summary: summary
      }
    end

    # Find best meeting times for a group
    # @param characters [Array<Character>]
    # @param limit [Integer]
    # @param threshold [Integer]
    # @return [Hash] { times:, summary: }
    def find_meeting_times(characters, limit: 5, threshold: DEFAULT_THRESHOLD)
      return { error: 'Need at least 2 characters' } if characters.length < 2

      # Filter to characters with shared profiles
      shareable = characters.select do |char|
        profile = ActivityProfile.for_character(char)
        profile.share_schedule && profile.has_sufficient_data?
      end

      if shareable.length < 2
        return { error: 'Not enough characters with schedule sharing enabled or sufficient data' }
      end

      times = ActivityProfile.find_best_meeting_times(shareable, limit: limit, threshold: threshold)

      {
        times: times,
        total_characters: characters.length,
        shareable_characters: shareable.length,
        summary: build_meeting_summary(times, shareable)
      }
    end

    # ===== Display Helpers =====

    # Format hour as 12-hour time
    # @param hour [Integer] 0-23
    # @return [String] e.g., "3:00 PM"
    def format_hour(hour)
      if hour.zero?
        '12:00 AM'
      elsif hour < 12
        "#{hour}:00 AM"
      elsif hour == 12
        '12:00 PM'
      else
        "#{hour - 12}:00 PM"
      end
    end

    # Format hour range from array of hours
    # @param hours [Array<Integer>]
    # @return [String] e.g., "2:00 PM-5:00 PM, 8:00 PM-11:00 PM"
    def format_hour_range(hours)
      return 'various times' if hours.empty?

      # Group consecutive hours
      sorted = hours.sort
      ranges = []
      current_range = [sorted.first]

      sorted[1..]&.each do |h|
        if h == current_range.last + 1
          current_range << h
        else
          ranges << current_range
          current_range = [h]
        end
      end
      ranges << current_range if current_range.any?

      ranges.map do |range|
        if range.length == 1
          format_hour(range.first)
        else
          "#{format_hour(range.first)}-#{format_hour((range.last + 1) % 24)}"
        end
      end.join(', ')
    end

    # Get full day name
    # @param day [String] short day name (mon, tue, etc.)
    # @return [String] full day name
    def full_day_name(day)
      ActivityProfile::DAY_NAMES[day.to_s.downcase[0..2]] || day.capitalize
    end

    private

    def build_overlap_summary(percentage, best_days)
      return 'Very little schedule overlap found.' if percentage < 10
      return "Minimal overlap (#{percentage}%)." if percentage < 25

      if best_days.any?
        best = best_days.first
        day_name = full_day_name(best[:day])

        # Check if this day is significantly better than average
        avg_hours = best_days.sum { |d| d[:overlap_hours].length } / [best_days.length, 1].max.to_f
        better_day = best[:overlap_hours].length > avg_hours * 1.3

        if better_day && best[:overlap_hours].length >= 2
          "#{percentage}% overlap. Better on #{day_name}s (#{format_hour_range(best[:overlap_hours])})."
        elsif best[:overlap_hours].length >= 3
          "#{percentage}% overlap. Best times: #{day_name} #{format_hour_range(best[:overlap_hours])}."
        else
          "#{percentage}% overlap overall."
        end
      else
        "#{percentage}% overlap overall."
      end
    end

    def build_meeting_summary(times, characters)
      return 'No common availability found.' if times.empty?

      best = times.first
      day_name = full_day_name(best[:day])
      hour_str = format_hour(best[:hour])
      count = best[:attendee_count]
      total = characters.length

      if count == total
        "Best time: #{day_name} at #{hour_str} (all #{total} available)"
      else
        "Best time: #{day_name} at #{hour_str} (#{count}/#{total} available)"
      end
    end
  end
end
