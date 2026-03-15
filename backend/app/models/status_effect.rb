# frozen_string_literal: true

# Defines status effects that can be applied to fight participants.
# Effects modify combat behavior (movement, damage, etc.) for a duration.
class StatusEffect < Sequel::Model
  include JsonbParsing

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  one_to_many :participant_status_effects

  # Effect types
  EFFECT_TYPES = %w[
    movement
    incoming_damage
    outgoing_damage
    healing
    stat_modifier
    damage_tick
    healing_tick
    action_restriction
    targeting_restriction
    damage_reduction
    protection
    shield
    fear
    grapple
  ].freeze

  # Stacking behaviors
  STACKING_BEHAVIORS = %w[refresh stack duration ignore].freeze

  def validate
    super
    validates_presence [:name, :effect_type]
    validates_unique :name
    validates_includes EFFECT_TYPES, :effect_type if effect_type
    validates_includes STACKING_BEHAVIORS, :stacking_behavior if stacking_behavior
    validates_max_length 50, :name
  end

  # Parse mechanics from JSONB
  def parsed_mechanics
    parse_jsonb_hash(mechanics)
  end

  # Check if this is a buff (positive effect)
  def buff?
    is_buff == true
  end

  # Check if this is a debuff (negative effect)
  def debuff?
    !buff?
  end

  # Get the modifier value from mechanics
  # @return [Integer] the modifier value (can be positive or negative)
  def modifier_value
    parsed_mechanics['modifier'].to_i
  end

  # Check if this effect blocks movement
  def blocks_movement?
    effect_type == 'movement' && parsed_mechanics['can_move'] == false
  end

  # Check if effect can stack
  def stackable?
    stacking_behavior == 'stack'
  end

  # Check if effect refreshes duration on reapplication
  def refreshable?
    stacking_behavior == 'refresh'
  end
end
