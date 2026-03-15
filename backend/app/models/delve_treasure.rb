# frozen_string_literal: true

# DelveTreasure represents a lootable treasure container in a terminal room.
# Value doubles with each dungeon level.
return unless DB.table_exists?(:delve_treasures)

class DelveTreasure < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve_room

  # Era-themed container types
  CONTAINERS = {
    medieval: 'wooden chest',
    gaslight: 'brass strongbox',
    modern: 'metal safe',
    near_future: 'secure container',
    scifi: 'stasis pod'
  }.freeze

  def validate
    super
    validates_presence [:delve_room_id]
    validates_unique :delve_room_id
  end

  def before_save
    super
    self.gold_value ||= 0
    self.looted = false if looted.nil?
  end

  # ====== State Checks ======

  def looted?
    looted == true
  end

  def available?
    !looted?
  end

  # ====== Actions ======

  # Loot this treasure
  def loot!
    update(looted: true, looted_at: Time.now)
  end

  # ====== Display ======

  def description
    container = container_type || 'container'

    if looted?
      "An empty #{container} sits here, already plundered."
    else
      "A #{container} catches your eye. It looks valuable."
    end
  end

  # Get value description without revealing exact amount
  def value_hint
    case gold_value
    when 0..10 then 'a few coins'
    when 11..30 then 'a modest sum'
    when 31..60 then 'a respectable haul'
    when 61..100 then 'a valuable treasure'
    else 'a king\'s ransom'
    end
  end

  # ====== Class Methods ======

  class << self
    # Calculate treasure value for a given level
    # Base: 5-10g, doubles each level
    # @param level [Integer] dungeon level
    # @param rng [Random] optional random generator
    def calculate_value(level, rng = nil)
      rng ||= Random.new

      base_min = GameSetting.integer('delve_base_treasure_min') ||
                 GameSetting.integer('delve_treasure_base_min') || 5
      base_max = GameSetting.integer('delve_base_treasure_max') ||
                 GameSetting.integer('delve_treasure_base_max') || 10

      multiplier = 2**(level - 1)
      min_value = base_min * multiplier
      max_value = base_max * multiplier

      rng.rand(min_value..max_value)
    end

    # Get container type for an era
    # @param era [Symbol, String] the current game era
    def container_for_era(era)
      CONTAINERS[era.to_sym] || 'container'
    end
  end
end
