# frozen_string_literal: true

# NpcSchedule defines where NPCs can be at different times.
# NPCs have probabilities of being in locations at given times.
class NpcSchedule < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character  # The NPC
  many_to_one :room
  one_to_many :npc_spawn_instances

  # Legacy day_of_week values (still supported)
  DAYS = %w[monday tuesday wednesday thursday friday saturday sunday any].freeze
  LEGACY_DAY_INDEX_TO_NAME = {
    0 => 'sunday',
    1 => 'monday',
    2 => 'tuesday',
    3 => 'wednesday',
    4 => 'thursday',
    5 => 'friday',
    6 => 'saturday'
  }.freeze

  # New weekdays patterns
  WEEKDAY_PATTERNS = %w[all weekdays weekends monday tuesday wednesday thursday friday saturday sunday].freeze

  def validate
    super
    validates_presence [:character_id, :room_id]
    validates_includes WEEKDAY_PATTERNS, :weekdays if weekdays

    if day_of_week
      if day_of_week.is_a?(Integer) || day_of_week.to_s.strip.match?(/\A\d+\z/)
        day_index = day_of_week.to_i
        errors.add(:day_of_week, 'must be between 0 and 6') if day_index < 0 || day_index > 6
      else
        normalized_day = day_of_week.to_s.strip.downcase
        if !normalized_day.empty? && !DAYS.include?(normalized_day)
          errors.add(:day_of_week, 'is not a valid day')
        end
      end
    end

    # Validate numeric ranges
    if probability && (probability < 0 || probability > 100)
      errors.add(:probability, 'must be between 0 and 100')
    end
    if start_hour && (start_hour < 0 || start_hour > 23)
      errors.add(:start_hour, 'must be between 0 and 23')
    end
    if end_hour && (end_hour < 0 || end_hour > 24)
      errors.add(:end_hour, 'must be between 0 and 24')
    end
    if start_hour && end_hour && start_hour == end_hour
      errors.add(:end_hour, 'must be different from start_hour')
    end
  end

  def before_save
    super
    # day_of_week is a legacy field - preserve nil weekdays when day_of_week is present
    # so legacy fallback matching can still work.
    self.weekdays = 'all' if weekdays.nil? && day_of_week.nil?
    self.probability ||= 100
    self.start_hour ||= 0
    self.end_hour ||= 24
    self.max_npcs ||= 1
  end

  # Check if this schedule applies right now
  def applies_now?(current_time = Time.now)
    return false unless is_active

    day_matches?(current_time) && time_matches?(current_time)
  end

  # Roll probability to see if NPC should spawn
  def should_spawn?
    applies_now? && rand(100) < probability
  end

  # Check if day matches using the new weekdays pattern (preferred) or legacy day_of_week
  def day_matches?(time = Time.now)
    day_name = time.strftime('%A').downcase

    # Use new weekdays field if available, otherwise fall back to legacy day_of_week.
    weekdays_pattern = weekdays.to_s.strip
    pattern = if !weekdays_pattern.empty?
                weekdays_pattern.downcase
              else
                legacy_day_pattern
              end
    pattern = 'all' if pattern.nil? || pattern.empty?

    case pattern
    when 'all', 'any', nil, ''
      true
    when 'weekdays'
      !%w[saturday sunday].include?(day_name)
    when 'weekends'
      %w[saturday sunday].include?(day_name)
    else
      pattern == day_name
    end
  end

  def legacy_day_pattern
    return nil if day_of_week.nil?

    if day_of_week.is_a?(Integer) || day_of_week.to_s.strip.match?(/\A\d+\z/)
      LEGACY_DAY_INDEX_TO_NAME[day_of_week.to_i]
    else
      day_of_week.to_s.strip.downcase
    end
  end

  # Check if current hour is within the schedule window
  def time_matches?(time = Time.now)
    return false if start_hour.nil? || end_hour.nil? || start_hour == end_hour

    hour = time.hour
    if end_hour > start_hour
      hour >= start_hour && hour < end_hour
    else
      # Handles overnight schedules (e.g., 22:00 - 06:00)
      hour >= start_hour || hour < end_hour
    end
  end

  # Get the currently active spawn instance for this schedule
  def active_spawn
    NpcSpawnInstance.first(npc_schedule_id: id, active: true)
  end

  # Count current spawns from this schedule
  def current_spawn_count
    NpcSpawnInstance.where(npc_schedule_id: id, active: true).count
  end

  # Can spawn more NPCs from this schedule?
  def can_spawn_more?
    current_spawn_count < (max_npcs || 1)
  end

  # Legacy compatibility - use should_spawn? instead
  alias_method :should_be_here?, :should_spawn?

  # Class methods
  class << self
    # Get schedules that apply right now
    def applicable_now(current_time = Time.now)
      where(is_active: true).all.select { |s| s.applies_now?(current_time) }
    end

    def for_room(room_id)
      where(room_id: room_id, is_active: true)
    end

    def for_character(character_id)
      where(character_id: character_id, is_active: true)
    end

    # Get current location for an NPC based on schedule
    def current_location_for(npc)
      applicable = where(character_id: npc.id, is_active: true)
        .all
        .select(&:applies_now?)
        .sort_by { |s| -(s.probability || 100) }

      applicable.find(&:should_spawn?)&.room
    end

    # Get all possible locations for an NPC
    def locations_for(npc)
      where(character_id: npc.id).eager(:room).all.map(&:room).uniq
    end
  end
end
