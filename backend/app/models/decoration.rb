# frozen_string_literal: true

class Decoration < Sequel::Model
  include StringHelper

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room

  def validate
    super
    validates_presence [:name]
    validates_max_length 100, :name
  end

  def has_image?
    present?(image_url)
  end
  alias image? has_image?

  def display_name
    name
  end

  def self.in_room(room_id)
    where(room_id: room_id)
  end

  def self.ordered
    order(:display_order)
  end
end
