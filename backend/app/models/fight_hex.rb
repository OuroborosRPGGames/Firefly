# frozen_string_literal: true

class FightHex < Sequel::Model(:fight_hexes)
  plugin :validation_helpers

  many_to_one :fight

  HEX_TYPES = %w[oil sharp_ground fire puddle long_fall open_window].freeze
  RENDER_PRIORITY = { 'fire' => 0, 'oil' => 1, 'sharp_ground' => 2, 'puddle' => 3, 'long_fall' => 4, 'open_window' => 5 }.freeze

  def validate
    super
    validates_presence [:fight_id, :hex_x, :hex_y, :hex_type]
    validates_includes HEX_TYPES, :hex_type
  end

  # Get all fight hex overlays for a position, sorted by render priority
  def self.at(fight_id, hex_x, hex_y)
    where(fight_id: fight_id, hex_x: hex_x, hex_y: hex_y)
      .all
      .sort_by { |fh| RENDER_PRIORITY[fh.hex_type] || 99 }
  end

  # Get all fight hexes for a fight, indexed by coordinate string
  def self.lookup_for_fight(fight_id)
    where(fight_id: fight_id).all.group_by { |fh| "#{fh.hex_x},#{fh.hex_y}" }
  end

  def self.has_type_at?(fight_id, hex_x, hex_y, hex_type)
    where(fight_id: fight_id, hex_x: hex_x, hex_y: hex_y, hex_type: hex_type).any?
  end
end
