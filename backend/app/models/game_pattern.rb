# frozen_string_literal: true

return unless DB.table_exists?(:game_patterns)

class GamePattern < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  SHARE_TYPES = %w[private public purchasable].freeze

  many_to_one :creator, class: :Character, key: :created_by

  def branches_dataset
    GamePatternBranch.where(game_pattern_id: id).order(:position)
  end

  def branches
    branches_dataset.all
  end

  def instances_dataset
    GameInstance.where(game_pattern_id: id)
  end

  def instances
    instances_dataset.all
  end

  def validate
    super
    validates_presence [:name, :created_by]
    validates_max_length 100, :name
    validates_includes SHARE_TYPES, :share_type, allow_nil: true
  end

  def display_name
    name
  end

  def scoring?
    has_scoring == true
  end

  def public?
    share_type == 'public'
  end

  def purchasable?
    share_type == 'purchasable'
  end
end
