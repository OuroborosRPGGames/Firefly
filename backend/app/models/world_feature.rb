# frozen_string_literal: true

return unless DB.table_exists?(:world_features)

class WorldFeature < Sequel::Model(:world_features)
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world

  def validate
    super
    validates_presence [:world_id, :name, :feature_type]
    validates_includes WorldHex::FEATURE_TYPES, :feature_type
    validates_unique [:world_id, :name]
    validates_max_length 255, :name
  end

  def to_api_hash
    {
      id: id,
      world_id: world_id,
      name: name,
      feature_type: feature_type
    }
  end
end
