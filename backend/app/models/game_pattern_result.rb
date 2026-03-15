# frozen_string_literal: true

return unless DB.table_exists?(:game_pattern_results)

class GamePatternResult < Sequel::Model
  plugin :validation_helpers

  many_to_one :game_pattern_branch

  def validate
    super
    validates_presence [:game_pattern_branch_id, :position, :message]
    validates_integer :position
    errors.add(:position, 'must be at least 1') if position && position < 1
  end

  def best?
    position == 1
  end

  def worst?
    return false unless game_pattern_branch

    position == game_pattern_branch.result_count
  end

  def point_value
    points || 0
  end
end
