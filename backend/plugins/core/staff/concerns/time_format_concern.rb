# frozen_string_literal: true

module Commands
  module Staff
    module Concerns
      # Shared helper for formatting the age of timestamped records (e.g. memory_at).
      #
      # Used by Reputation and SearchMemory commands.
      module TimeFormatConcern
        # Return a human-readable age string relative to now.
        #
        # @param timestamp [Time, nil]
        # @return [String] e.g. "today", "1 day ago", "5 days ago", or "unknown"
        def format_age(timestamp)
          return 'unknown' unless timestamp

          days = ((Time.now - timestamp) / 86_400).to_i
          case days
          when 0 then 'today'
          when 1 then '1 day ago'
          else "#{days} days ago"
          end
        end
      end
    end
  end
end
