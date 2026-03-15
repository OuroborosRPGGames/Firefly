# frozen_string_literal: true

return unless DB.table_exists?(:game_scores)

class GameScore < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :game_instance
  many_to_one :character_instance

  def validate
    super
    validates_presence [:game_instance_id, :character_instance_id]
  end

  def add_points(points)
    delta = points.to_i
    self.class.where(id: id).update(score: Sequel.lit('COALESCE(score, 0) + ?', delta))
    refresh
  end

  def reset!
    update(score: 0)
  end

  # Find or create score record for a player
  def self.for_player(game_instance, character_instance)
    find_or_create(
      game_instance_id: game_instance.id,
      character_instance_id: character_instance.id
    ) { |s| s.score = 0 }
  end

  # Clear all scores for a character leaving a room
  def self.clear_for_room(room_id, character_instance_id)
    # Find all game instances in this room
    room_game_ids = GameInstance.where(room_id: room_id).select_map(:id)
    return if room_game_ids.empty?

    # Delete scores for those games
    where(
      game_instance_id: room_game_ids,
      character_instance_id: character_instance_id
    ).delete
  end

  # Clear all scores for games attached to items owned by character
  def self.clear_for_items(character_instance_id)
    # Find items owned by this character
    item_ids = Item.where(character_instance_id: character_instance_id).select_map(:id)
    return if item_ids.empty?

    # Find game instances on those items
    item_game_ids = GameInstance.where(item_id: item_ids).select_map(:id)
    return if item_game_ids.empty?

    # Delete scores
    where(
      game_instance_id: item_game_ids,
      character_instance_id: character_instance_id
    ).delete
  end
end
