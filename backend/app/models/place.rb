# frozen_string_literal: true

class Place < Sequel::Model
  include StringHelper

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room
  one_to_many :character_instances, key: :current_place_id

  def validate
    super
    validates_presence [:name]
    validates_max_length 100, :name
  end

  def characters_here(reality_id = nil, viewer: nil)
    query = character_instances_dataset.where(online: true)
    query = query.where(reality_id: reality_id) if reality_id
    query = query.where(in_event_id: viewer.in_event_id) if viewer
    query
  end

  def full?
    return false unless capacity
    character_instances_dataset.count >= capacity
  end

  def display_name
    name
  end

  def furniture?
    is_furniture == true
  end

  def visible?
    !invisible
  end

  def has_image?
    present?(image_url)
  end
  alias image? has_image?

  def self.visible
    where(invisible: false)
  end

  def self.in_room(room_id)
    where(room_id: room_id)
  end
end
