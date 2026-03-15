# frozen_string_literal: true

return unless DB.table_exists?(:game_pattern_branches)

class GamePatternBranch < Sequel::Model
  plugin :validation_helpers

  many_to_one :game_pattern
  many_to_one :stat

  def results_dataset
    GamePatternResult.where(game_pattern_branch_id: id).order(:position)
  end

  def results
    results_dataset.all
  end

  def validate
    super
    validates_presence [:game_pattern_id, :name, :display_name]
    validates_max_length 50, :name
    validates_max_length 100, :display_name
  end

  def uses_stat?
    !stat_id.nil?
  end

  def result_count
    results_dataset.count
  end
end
