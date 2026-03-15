# frozen_string_literal: true

# Defines a type of large multi-segment monster (colossus, dragon, etc.)
# Contains configuration for HP, size, segments, and climbing mechanics.
class MonsterTemplate < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  one_to_many :monster_segment_templates, order: :display_order
  one_to_many :large_monster_instances, class: :LargeMonsterInstance, key: :monster_template_id
  one_to_many :npc_archetypes
  many_to_one :npc_archetype

  MONSTER_TYPES = %w[colossus dragon behemoth titan golem hydra serpent].freeze

  def validate
    super
    validates_presence [:name, :total_hp, :hex_width, :hex_height, :climb_distance, :defeat_threshold_percent]
    validates_unique :name
    validates_max_length 100, :name
    validates_includes MONSTER_TYPES, :monster_type if monster_type
    validates_integer :total_hp
    validates_integer :hex_width
    validates_integer :hex_height
    validates_integer :climb_distance
    validates_integer :defeat_threshold_percent
  end

  # Get the weak point segment template
  # @return [MonsterSegmentTemplate, nil]
  def weak_point_segment
    monster_segment_templates_dataset.where(is_weak_point: true).first
  end

  # Get all segments required for mobility
  # @return [Array<MonsterSegmentTemplate>]
  def mobility_segments
    monster_segment_templates_dataset.where(required_for_mobility: true).all
  end

  # Get all limb-type segments
  # @return [Array<MonsterSegmentTemplate>]
  def limb_segments
    monster_segment_templates_dataset.where(segment_type: 'limb').all
  end

  # Calculate the HP for a specific segment based on its percentage
  # @param segment_template [MonsterSegmentTemplate]
  # @return [Integer]
  def calculate_segment_hp(segment_template)
    ((total_hp * segment_template.hp_percent) / 100.0).round
  end

  # Get total HP percentage allocated to all segments
  # Should sum to 100 for proper distribution
  # @return [Integer]
  def total_segment_hp_percent
    monster_segment_templates.sum(&:hp_percent)
  end

  # Parse behavior config from JSONB
  # @return [Hash]
  def parsed_behavior_config
    return {} unless behavior_config

    if behavior_config.respond_to?(:to_hash)
      behavior_config.to_hash
    elsif behavior_config.is_a?(String)
      JSON.parse(behavior_config)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Get shake-off threshold (number of mounted players before monster tries to shake)
  # @return [Integer]
  def shake_off_threshold
    parsed_behavior_config['shake_off_threshold'] || 2
  end

  # Get range of segments that attack per round
  # @return [Array<Integer>] e.g., [2, 3] means 2-3 segments attack
  def segment_attack_count_range
    range = parsed_behavior_config['segment_attack_count']
    return [2, 3] unless range.is_a?(Array) && range.length == 2

    range.map(&:to_i)
  end

  # Get all hexes this monster would occupy at a given center position
  # @param center_x [Integer]
  # @param center_y [Integer]
  # @return [Array<Array<Integer>>] Array of [x, y] pairs
  def occupied_hexes_at(center_x, center_y)
    x_offsets = centered_offsets(hex_width)
    y_offsets = centered_offsets(hex_height).map { |row| row * 2 }
    min_x = center_x + x_offsets.min
    max_x = center_x + x_offsets.max
    min_y = center_y + y_offsets.min
    max_y = center_y + y_offsets.max

    hexes = []
    x_offsets.each do |dx|
      y_offsets.each do |dy|
        raw_x = center_x + dx
        raw_y = center_y + dy
        hy = ((raw_y.to_f / 2).round * 2).clamp(min_y, max_y)
        hx = snap_x_for_row(raw_x, hy, min_x, max_x)
        hexes << [hx, hy]
      end
    end

    hexes.uniq
  end

  # Create a monster instance for a fight
  # @param fight [Fight]
  # @param center_x [Integer]
  # @param center_y [Integer]
  # @return [LargeMonsterInstance]
  def spawn_in_fight(fight, center_x, center_y)
    center_x, center_y = HexGrid.to_hex_coords(center_x, center_y)

    instance = LargeMonsterInstance.create(
      monster_template_id: id,
      fight_id: fight.id,
      current_hp: total_hp,
      max_hp: total_hp,
      center_hex_x: center_x,
      center_hex_y: center_y,
      status: 'active'
    )

    # Create segment instances
    monster_segment_templates.each do |seg_template|
      seg_hp = calculate_segment_hp(seg_template)
      MonsterSegmentInstance.create(
        large_monster_instance_id: instance.id,
        monster_segment_template_id: seg_template.id,
        current_hp: seg_hp,
        max_hp: seg_hp,
        status: 'healthy',
        can_attack: true,
        attacks_remaining_this_round: seg_template.attacks_per_round
      )
    end

    # Mark fight as having a monster
    fight.update(has_monster: true)

    instance
  end

  private

  # Build integer offsets centered around zero.
  # count=3 -> [-1,0,1], count=2 -> [-1,0], count=1 -> [0]
  def centered_offsets(count)
    count = [count.to_i, 1].max
    start = -(count / 2)
    finish = start + count - 1
    (start..finish).to_a
  end

  # Snap X to a valid parity for the given Y row while staying in bounds.
  def snap_x_for_row(raw_x, row_y, min_x, max_x)
    candidates = (min_x..max_x).select do |x|
      if (row_y / 2).even?
        x.even?
      else
        x.odd?
      end
    end

    return raw_x if candidates.empty?

    candidates.min_by { |x| (x - raw_x).abs }
  end
end
