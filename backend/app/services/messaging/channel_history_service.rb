# frozen_string_literal: true

# Manages channel/messaging mode history for arrow-key cycling in the left panel.
# History is stored as a JSONB array on character_instances, ordered most-recent-first.
# Index 0 = most recent mode change, cursor tracks current position.
class ChannelHistoryService
  MAX_HISTORY = 25

  # Push the current messaging state onto the history stack.
  # Deduplicates: if an identical entry already exists, it's removed before prepending.
  # Resets cursor to 0.
  def self.push(character_instance)
    entry = build_entry(character_instance)
    return unless entry

    history = current_history(character_instance)

    # Deduplicate: remove any existing entry that matches this one
    history.reject! { |h| same_entry?(h, entry) }

    # Prepend new entry and cap at max
    history.unshift(entry)
    history = history.first(MAX_HISTORY)

    character_instance.update(
      channel_history: Sequel.pg_jsonb_wrap(history),
      channel_history_cursor: 0
    )
    character_instance.refresh
  end

  # Cycle through history in the given direction ('up' or 'down').
  # Returns nil if no change (at boundary or empty history).
  # Otherwise applies the entry and returns the new cursor value.
  def self.cycle(character_instance, direction)
    history = current_history(character_instance)
    return nil if history.empty?

    cursor = character_instance.channel_history_cursor || 0

    new_cursor = case direction.to_s
                 when 'up'
                   cursor + 1
                 when 'down'
                   cursor - 1
                 else
                   return nil
                 end

    # Clamp to valid range
    new_cursor = new_cursor.clamp(0, history.length - 1)

    # No change if we're already at the boundary
    return nil if new_cursor == cursor

    entry = history[new_cursor]
    return nil unless entry

    apply_entry(character_instance, entry, new_cursor)
    new_cursor
  end

  # Reset cursor to 0 (called when user sends a new message).
  def self.reset_cursor(character_instance)
    character_instance.update(channel_history_cursor: 0)
  end

  # --- Private helpers ---

  def self.build_entry(character_instance)
    mode = character_instance.messaging_mode || 'channel'

    {
      'mode' => mode,
      'channel_id' => character_instance.current_channel_id,
      'channel_name' => character_instance.last_channel_name,
      'ooc_target_ids' => safe_array(character_instance.current_ooc_target_ids),
      'ooc_target_names' => character_instance.ooc_target_names,
      'msg_target_char_ids' => safe_array(character_instance.msg_target_character_ids),
      'msg_target_names' => character_instance.msg_target_names
    }
  end

  def self.current_history(character_instance)
    raw = character_instance.channel_history
    if raw.respond_to?(:to_a)
      raw.to_a.map { |h| h.respond_to?(:to_h) ? h.to_h : h }
    elsif raw.is_a?(String)
      JSON.parse(raw) rescue []
    else
      []
    end
  end

  def self.same_entry?(a, b)
    return false unless a && b

    a['mode'] == b['mode'] &&
      a['channel_id'] == b['channel_id'] &&
      a['channel_name'] == b['channel_name'] &&
      sorted_ids(a['ooc_target_ids']) == sorted_ids(b['ooc_target_ids']) &&
      sorted_ids(a['msg_target_char_ids']) == sorted_ids(b['msg_target_char_ids'])
  end

  def self.sorted_ids(ids)
    return [] if ids.nil?

    Array(ids).map(&:to_i).sort
  end

  def self.safe_array(val)
    return nil if val.nil?

    Array(val).map(&:to_i)
  end

  def self.apply_entry(character_instance, entry, new_cursor)
    updates = {
      messaging_mode: entry['mode'] || 'channel',
      current_channel_id: entry['channel_id'],
      last_channel_name: entry['channel_name'],
      ooc_target_names: entry['ooc_target_names'],
      msg_target_names: entry['msg_target_names'],
      channel_history_cursor: new_cursor
    }

    # Handle array columns
    ooc_ids = entry['ooc_target_ids']
    updates[:current_ooc_target_ids] = ooc_ids ? Sequel.pg_array(ooc_ids.map(&:to_i)) : Sequel.pg_array([])

    msg_ids = entry['msg_target_char_ids']
    updates[:msg_target_character_ids] = msg_ids ? Sequel.pg_array(msg_ids.map(&:to_i)) : Sequel.pg_array([])

    character_instance.update(updates)
    character_instance.refresh
  end

  private_class_method :build_entry, :current_history, :same_entry?,
                       :sorted_ids, :safe_array, :apply_entry
end
