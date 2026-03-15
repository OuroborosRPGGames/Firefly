# frozen_string_literal: true

return unless DB.table_exists?(:game_instances)

class GameInstance < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :game_pattern
  many_to_one :item
  many_to_one :room

  def scores_dataset
    GameScore.where(game_instance_id: id)
  end

  def scores
    scores_dataset.all
  end

  def validate
    super
    validates_presence [:game_pattern_id]
    validates_max_length 100, :custom_name, allow_nil: true

    if item_id && room_id
      errors.add(:base, 'Cannot be attached to both an item and a room')
    elsif !item_id && !room_id
      errors.add(:base, 'Must be attached to either an item or a room')
    end
  end

  def display_name
    custom_name || game_pattern&.name || 'Unknown Game'
  end

  def room_fixture?
    !room_id.nil?
  end

  def item_attached?
    !item_id.nil?
  end

  def scoring?
    game_pattern&.scoring? || false
  end

  def branches
    game_pattern&.branches || []
  end

  def single_branch?
    branches.count == 1
  end
end
