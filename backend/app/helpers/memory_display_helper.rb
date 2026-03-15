# frozen_string_literal: true

# Shared helper for formatting the age of memory records.
#
# Used by Reputation and Searchmemory staff commands.
module MemoryDisplayHelper
  def format_age(memory_at)
    return 'unknown' unless memory_at

    days = ((Time.now - memory_at) / 86_400).to_i
    case days
    when 0 then 'today'
    when 1 then '1 day ago'
    else "#{days} days ago"
    end
  end
end
