# frozen_string_literal: true

# Caches battle map hex data for delve rooms by combo key.
# Same-shaped delve rooms (same exits + content) share the same battle map
# template, avoiding redundant procedural/AI generation.
#
# Schema:
#   id              - primary key
#   combo_key       - unique string identifying room shape + content (e.g., "corridor:ns:monster")
#   hex_data        - JSONB array of hex attributes for bulk-creating RoomHex records
#   background_url  - optional background image URL
#   background_contrast - 'dark' or 'light' (default: 'dark')
#   created_at      - when the template was first cached
#   last_used_at    - when the template was last applied to a room
class DelveBattleMapTemplate < Sequel::Model(:delve_battle_map_templates)
  # Find a cached template by combo key.
  # @param combo_key [String] e.g., "corridor:ns:monster"
  # @return [DelveBattleMapTemplate, nil]
  def self.find_by_combo(combo_key)
    first(combo_key: combo_key)
  end

  # Cache hex data for a combo key. Creates or updates the template.
  # @param combo_key [String] the combo key
  # @param hex_data [Array<Hash>] array of hex attribute hashes (without room_id)
  # @param background_url [String, nil] optional background image URL
  # @param background_contrast [String] 'dark' or 'light'
  # @return [DelveBattleMapTemplate]
  def self.cache_hex_data!(combo_key, hex_data:, background_url: nil, background_contrast: 'dark')
    attrs = {
      hex_data: Sequel.pg_jsonb_wrap(hex_data),
      background_url: background_url,
      background_contrast: background_contrast,
      last_used_at: Time.now
    }

    existing = find_by_combo(combo_key)
    if existing
      existing.update(attrs)
      existing
    else
      create(attrs.merge(combo_key: combo_key))
    end
  rescue Sequel::UniqueConstraintViolation
    # Another process inserted concurrently — update the existing record
    existing = find_by_combo(combo_key)
    existing&.update(attrs)
    existing
  end

  # Update last_used_at timestamp.
  def touch!
    update(last_used_at: Time.now)
  end
end
