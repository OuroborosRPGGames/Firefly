# frozen_string_literal: true

# Tracks character activity patterns for schedule overlap calculation.
#
# Stores aggregated activity in 168 hourly buckets (7 days x 24 hours).
# Used to calculate schedule overlap between players and find optimal meeting times.
#
# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_profiles)

class ActivityProfile < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character

  # Day/hour constants
  DAYS = %w[mon tue wed thu fri sat sun].freeze
  HOURS = (0..23).to_a.freeze

  # Day name mappings
  DAY_NAMES = {
    'mon' => 'Monday',
    'tue' => 'Tuesday',
    'wed' => 'Wednesday',
    'thu' => 'Thursday',
    'fri' => 'Friday',
    'sat' => 'Saturday',
    'sun' => 'Sunday'
  }.freeze

  def validate
    super
    validates_presence [:character_id]
    validates_unique [:character_id]
  end

  def before_save
    super
    self.activity_buckets ||= {}
  end

  # ===== Activity Recording =====

  # Record an activity sample for the current time
  # @param weight [Float] sample weight (0.0-1.0), default 1.0
  # @param time [Time] the time to record for (defaults to now)
  def record_sample!(weight: 1.0, time: Time.now)
    return unless tracking_enabled

    slot_key = self.class.slot_key_for(time)
    current_value = (parsed_buckets[slot_key] || 0).to_f

    # Blend new sample with existing (running average with decay)
    # Weight factor based on total samples for stability
    sample_factor = [0.1, 1.0 / ([total_samples || 1, 1].max**0.5)].max
    new_value = current_value * (1 - sample_factor) + (weight * 100) * sample_factor

    # Update bucket
    updated_buckets = parsed_buckets.dup
    updated_buckets[slot_key] = [new_value.round(1), 100].min

    update(
      activity_buckets: Sequel.pg_jsonb_wrap(updated_buckets),
      total_samples: (total_samples || 0) + 1,
      last_sample_at: time
    )
  end

  # Apply exponential decay to all buckets
  def apply_decay!
    return if parsed_buckets.empty?

    weeks_since_decay = if last_decay_applied_at
                          (Time.now - last_decay_applied_at) / (7 * 24 * 3600)
                        else
                          1.0
                        end

    return if weeks_since_decay < 1.0 # Only decay weekly

    decay_factor = 0.5**(weeks_since_decay / GameConfig::ActivityProfile::DECAY_HALF_LIFE_WEEKS)

    decayed_buckets = parsed_buckets.transform_values do |value|
      (value.to_f * decay_factor).round(1)
    end

    # Remove buckets that have decayed below 1
    decayed_buckets.reject! { |_, v| v < 1 }

    update(
      activity_buckets: Sequel.pg_jsonb_wrap(decayed_buckets),
      last_decay_applied_at: Time.now,
      weeks_tracked: (weeks_tracked || 0) + weeks_since_decay.floor
    )
  end

  # ===== Pattern Analysis =====

  # Get activity score for a specific day/hour
  # @param day [String, Symbol] 'mon', 'tue', etc.
  # @param hour [Integer] 0-23
  # @return [Float] 0-100 activity score
  def activity_at(day, hour)
    key = "#{day.to_s.downcase[0..2]}_#{hour}"
    (parsed_buckets[key] || 0).to_f
  end

  # Get peak activity times (sorted by activity score)
  # @param limit [Integer] max results
  # @param threshold [Integer] minimum activity score
  # @return [Array<Hash>] [{day:, hour:, score:}]
  def peak_times(limit: 10, threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
    parsed_buckets
      .select { |_, v| v >= threshold }
      .sort_by { |_, v| -v }
      .first(limit)
      .map do |key, score|
        day, hour = key.split('_')
        { day: day, hour: hour.to_i, score: score.round(1) }
      end
  end

  # Get typical weekly schedule (which slots are "likely online")
  # @param threshold [Integer] minimum activity score
  # @return [Hash] day => [hours]
  def weekly_schedule(threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
    schedule = DAYS.each_with_object({}) { |d, h| h[d] = [] }

    DAYS.each do |day|
      HOURS.each do |hour|
        score = activity_at(day, hour)
        schedule[day] << hour if score >= threshold
      end
    end

    schedule
  end

  # Check if character has enough data for meaningful overlap
  def has_sufficient_data?
    (total_samples || 0) >= 20
  end
  alias sufficient_data? has_sufficient_data?

  # ===== Overlap Calculation =====

  # Calculate overlap percentage with another profile
  # @param other [ActivityProfile]
  # @param threshold [Integer] minimum score to count as "available"
  # @return [Float] 0-100 overlap percentage
  def overlap_with(other, threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
    return 0.0 unless other.is_a?(ActivityProfile)

    overlap_score = 0.0
    total_score = 0.0

    DAYS.each do |day|
      HOURS.each do |hour|
        my_score = activity_at(day, hour)
        their_score = other.activity_at(day, hour)

        next if my_score < threshold && their_score < threshold

        if my_score >= threshold && their_score >= threshold
          overlap_score += [my_score, their_score].min
        end

        total_score += [my_score, their_score].max
      end
    end

    return 0.0 if total_score.zero?
    (overlap_score / total_score * 100).round(1)
  end

  # Find best overlap days (days with most shared availability)
  # @param other [ActivityProfile]
  # @param threshold [Integer]
  # @return [Array<Hash>] [{day:, overlap_hours:, score:}]
  def best_overlap_days(other, threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
    DAYS.map do |day|
      overlap_hours = []
      day_score = 0.0

      HOURS.each do |hour|
        my_score = activity_at(day, hour)
        their_score = other.activity_at(day, hour)

        if my_score >= threshold && their_score >= threshold
          overlap_hours << hour
          day_score += [my_score, their_score].min
        end
      end

      { day: day, overlap_hours: overlap_hours, score: day_score.round(1) }
    end
      .select { |d| d[:overlap_hours].any? }
      .sort_by { |d| -d[:score] }
  end

  # Find best overlap times (specific hours with best overlap)
  # @param other [ActivityProfile]
  # @param limit [Integer]
  # @param threshold [Integer]
  # @return [Array<Hash>] [{day:, hour:, score:}]
  def best_overlap_times(other, limit: 5, threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
    times = []

    DAYS.each do |day|
      HOURS.each do |hour|
        my_score = activity_at(day, hour)
        their_score = other.activity_at(day, hour)

        if my_score >= threshold && their_score >= threshold
          combined_score = [my_score, their_score].min
          times << { day: day, hour: hour, score: combined_score.round(1) }
        end
      end
    end

    times.sort_by { |t| -t[:score] }.first(limit)
  end

  # ===== Helper Methods =====

  # Parse activity_buckets from JSONB
  def parsed_buckets
    case activity_buckets
    when Hash
      activity_buckets
    when String
      JSON.parse(activity_buckets)
    else
      activity_buckets&.to_h || {}
    end
  rescue JSON::ParserError
    {}
  end

  # ===== Class Methods =====

  class << self
    # Get slot key for a given time
    # @param time [Time]
    # @return [String] e.g., "mon_14"
    def slot_key_for(time)
      day = time.strftime('%a').downcase
      hour = time.hour
      "#{day}_#{hour}"
    end

    # Find or create profile for a character
    def for_character(character)
      first(character_id: character.id) || create(character_id: character.id)
    end

    # Find best meeting times for multiple characters
    # @param characters [Array<Character>]
    # @param limit [Integer] max results
    # @param threshold [Integer] minimum activity score
    # @return [Array<Hash>] [{day:, hour:, attendees:, score:}]
    def find_best_meeting_times(characters, limit: 5, threshold: GameConfig::ActivityProfile::DEFAULT_THRESHOLD)
      return [] if characters.length < 2

      profiles = characters.map { |c| for_character(c) }

      # Filter to profiles that share their schedule
      shareable_indices = profiles.each_with_index.select { |p, _| p.share_schedule }.map(&:last)
      return [] if shareable_indices.length < 2

      # Build meeting times
      results = []

      DAYS.each do |day|
        HOURS.each do |hour|
          attendees = []
          total_score = 0.0

          shareable_indices.each do |idx|
            score = profiles[idx].activity_at(day, hour)
            if score >= threshold
              attendees << characters[idx]
              total_score += score
            end
          end

          next if attendees.length < 2 # Need at least 2 people

          results << {
            day: day,
            hour: hour,
            attendees: attendees,
            attendee_count: attendees.length,
            score: total_score.round(1)
          }
        end
      end

      # Sort by attendee count first, then by score
      results.sort_by { |s| [-s[:attendee_count], -s[:score]] }.first(limit)
    end
  end
end
