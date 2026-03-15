# frozen_string_literal: true

# Shared time duration formatting for services and handlers.
module TimeFormatHelper
  # Format a duration in seconds as human-readable text.
  #
  # @param seconds [Numeric]
  # @param style [Symbol] :full (default), :abbreviated, or :flashback
  # @return [String]
  def format_duration(seconds, style: :full)
    case style
    when :abbreviated
      format_duration_abbreviated(seconds)
    when :flashback
      format_duration_flashback(seconds)
    else
      format_duration_full(seconds)
    end
  end

  # Format the time gap between two Time objects as a narrative phrase.
  # Returns nil if the gap is under 2 minutes.
  #
  # @param from_time [Time]
  # @param to_time [Time]
  # @return [String, nil]
  def format_duration_gap(from_time, to_time)
    return nil unless from_time && to_time

    minutes = ((to_time - from_time) / 60).to_i
    return nil if minutes < 2

    case minutes
    when 2..59   then "(#{minutes} minutes later)"
    when 60..119 then '(An hour later)'
    when 120..1439 then "(#{minutes / 60} hours later)"
    else "(#{minutes / 1440} days later)"
    end
  end

  private

  def format_duration_full(seconds)
    if seconds >= 3600
      hours = (seconds / 3600.0).round(1)
      label = hours == hours.to_i ? hours.to_i : hours
      "#{label} hour#{'s' if label != 1}"
    elsif seconds >= 60
      minutes = (seconds / 60.0).round
      "#{minutes} minute#{'s' if minutes != 1}"
    else
      "#{seconds.to_i} second#{'s' if seconds.to_i != 1}"
    end
  end

  def format_duration_abbreviated(seconds)
    return '0s' if seconds <= 0

    if seconds >= 3600
      hours = seconds / 3600
      mins = (seconds % 3600) / 60
      mins > 0 ? "#{hours}h #{mins}min" : "#{hours}h"
    elsif seconds >= 60
      "#{(seconds / 60.0).ceil}min"
    else
      "#{seconds.to_i}s"
    end
  end

  def format_duration_flashback(seconds)
    return '0 seconds' if seconds <= 0

    if seconds < 60
      "#{seconds} seconds"
    elsif seconds < 3600
      minutes = (seconds / 60.0).round(1)
      minutes == minutes.to_i ? "#{minutes.to_i} minutes" : "#{minutes} minutes"
    else
      hours = seconds / 3600
      minutes = (seconds % 3600) / 60
      if minutes > 0
        "#{hours}h #{minutes}m"
      else
        hours == 1 ? '1 hour' : "#{hours} hours"
      end
    end
  end
end
