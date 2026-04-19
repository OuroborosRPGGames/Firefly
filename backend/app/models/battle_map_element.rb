# frozen_string_literal: true

class BattleMapElement < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :fight

  ELEMENT_TYPES = %w[water_barrel oil_barrel munitions_crate toxic_mushrooms lotus_pollen vase cliff_edge].freeze
  STATES = %w[intact broken ignited detonated].freeze
  BREAKABLE_TYPES = %w[water_barrel oil_barrel vase].freeze
  DETONATABLE_TYPES = %w[munitions_crate].freeze
  PLACEABLE_TYPES = %w[water_barrel oil_barrel munitions_crate toxic_mushrooms lotus_pollen vase].freeze
  CLUSTER_TYPES = %w[toxic_mushrooms lotus_pollen].freeze

  def validate
    super
    validates_presence [:fight_id, :element_type, :state]
    validates_includes ELEMENT_TYPES, :element_type
    validates_includes STATES, :state
    if element_type == 'cliff_edge'
      validates_presence [:edge_side]
      validates_includes %w[north south east west], :edge_side
    else
      validates_presence [:hex_x, :hex_y]
    end
  end

  def intact?
    state == 'intact'
  end

  def broken?
    state == 'broken'
  end

  def detonated?
    state == 'detonated'
  end

  def breakable?
    BREAKABLE_TYPES.include?(element_type) && intact?
  end

  def detonatable?
    DETONATABLE_TYPES.include?(element_type) && intact?
  end

  def break!
    update(state: 'broken')
  end

  def detonate!
    update(state: 'detonated')
  end
end
