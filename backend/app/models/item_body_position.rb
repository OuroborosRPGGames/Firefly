# frozen_string_literal: true

class ItemBodyPosition < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :item
  many_to_one :body_position

  def validate
    super
    validates_presence [:item_id, :body_position_id]
    validates_unique [:item_id, :body_position_id]
  end

  def covers?
    covers
  end

  def reveals?
    !covers
  end
end
