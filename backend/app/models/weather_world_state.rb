# frozen_string_literal: true

require 'msgpack'

class WeatherWorldState < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world

  def validate
    super
    validates_presence [:world_id]
    validates_unique [:world_id]
  end

  # Unpack grid data from MessagePack binary
  def grid_hash
    return {} if grid_data.nil?

    MessagePack.unpack(grid_data)
  rescue StandardError => e
    warn "[WeatherWorldState] Failed to unpack grid_data: #{e.message}"
    {}
  end

  # Pack grid data to MessagePack binary
  def grid_hash=(hash)
    self.grid_data = Sequel.blob(MessagePack.pack(hash))
  end

  # Unpack terrain data from MessagePack binary
  def terrain_hash
    return {} if terrain_data.nil?

    MessagePack.unpack(terrain_data)
  rescue StandardError => e
    warn "[WeatherWorldState] Failed to unpack terrain_data: #{e.message}"
    {}
  end

  # Pack terrain data to MessagePack binary
  def terrain_hash=(hash)
    self.terrain_data = Sequel.blob(MessagePack.pack(hash))
  end

  # Get storms as array (already JSONB)
  def storms
    storms_data || []
  end

  # Set storms array
  def storms=(arr)
    self.storms_data = arr
  end

  # Get metadata hash
  def meta
    meta_data || {}
  end

  # Set metadata
  def meta=(hash)
    self.meta_data = hash
  end
end
