# frozen_string_literal: true

# Seeds combat status effects for the advanced combat mechanics system.
# Run with: bundle exec ruby scripts/setup/seed_combat_status_effects.rb

require_relative '../../config/application'

EFFECTS = [
  # Damage over time effects
  {
    name: 'burning',
    effect_type: 'damage_tick',
    description: 'Taking fire damage each round. Can spread to adjacent targets.',
    mechanics: { damage: '4', damage_type: 'fire', spreadable: true, extinguish_action: true },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'fire'
  },
  {
    name: 'poisoned',
    effect_type: 'damage_tick',
    description: 'Taking poison damage each round.',
    mechanics: { damage: '1d4', damage_type: 'poison' },
    stacking_behavior: 'stack',
    max_stacks: 3,
    is_buff: false,
    icon_name: 'skull'
  },
  {
    name: 'bleeding',
    effect_type: 'damage_tick',
    description: 'Taking physical damage each round from blood loss.',
    mechanics: { damage: '1d6', damage_type: 'physical' },
    stacking_behavior: 'stack',
    max_stacks: 3,
    is_buff: false,
    icon_name: 'droplet'
  },
  {
    name: 'freezing',
    effect_type: 'damage_tick',
    description: 'Taking cold damage each round.',
    mechanics: { damage: '1d4', damage_type: 'cold' },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'snowflake'
  },

  # Healing over time effects
  {
    name: 'regenerating',
    effect_type: 'healing_tick',
    description: 'Slowly recovering health over time.',
    mechanics: { healing: '0.5' },
    stacking_behavior: 'refresh',
    is_buff: true,
    icon_name: 'heart-pulse'
  },
  {
    name: 'blessed',
    effect_type: 'healing_tick',
    description: 'Divine favor slowly restores health.',
    mechanics: { healing: '0.25' },
    stacking_behavior: 'stack',
    max_stacks: 4,
    is_buff: true,
    icon_name: 'sparkles'
  },

  # Movement effects
  {
    name: 'slowed',
    effect_type: 'movement',
    description: 'Movement speed reduced by half.',
    mechanics: { speed_multiplier: 0.5 },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'snail'
  },
  {
    name: 'immobilized',
    effect_type: 'movement',
    description: 'Cannot move.',
    mechanics: { can_move: false },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'lock'
  },
  {
    name: 'prone',
    effect_type: 'movement',
    description: 'Knocked to the ground. Must spend movement to stand.',
    mechanics: { prone: true, stand_cost: 2 },
    stacking_behavior: 'ignore',
    is_buff: false,
    icon_name: 'person-falling'
  },

  # Action restriction effects
  {
    name: 'dazed',
    effect_type: 'action_restriction',
    description: 'Cannot use tactical actions.',
    mechanics: { blocks_tactical: true },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'stars'
  },
  {
    name: 'stunned',
    effect_type: 'action_restriction',
    description: 'Cannot use main or tactical actions.',
    mechanics: { blocks_main: true, blocks_tactical: true },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'zap'
  },

  # Targeting restriction effects
  {
    name: 'taunted',
    effect_type: 'targeting_restriction',
    description: 'Must attack the taunter or suffer a penalty.',
    mechanics: { must_target_id: nil, penalty_otherwise: -4 },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'megaphone'
  },

  # Fear effects
  {
    name: 'frightened',
    effect_type: 'fear',
    description: 'Afraid of the source. Attack penalty and cannot approach.',
    mechanics: { flee_from_id: nil, attack_penalty: -2 },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'ghost'
  },

  # Shield effects
  {
    name: 'shielded',
    effect_type: 'shield',
    description: 'Protected by a magical shield that absorbs damage.',
    mechanics: { type: 'hp', amount: 2, types_absorbed: ['all'] },
    stacking_behavior: 'stack',
    max_stacks: 5,
    is_buff: true,
    icon_name: 'shield'
  },

  # Damage reduction effects
  {
    name: 'protected',
    effect_type: 'damage_reduction',
    description: 'Taking reduced damage from all sources.',
    mechanics: { flat_reduction: 5, types: ['all'] },
    stacking_behavior: 'refresh',
    is_buff: true,
    icon_name: 'shield-check'
  },

  # Outgoing damage effects
  {
    name: 'empowered',
    effect_type: 'outgoing_damage',
    description: 'Dealing bonus damage with attacks.',
    mechanics: { bonus: 5 },
    stacking_behavior: 'refresh',
    is_buff: true,
    icon_name: 'sword'
  },

  # Incoming damage modifier effects (vulnerability/resistance/immunity)
  {
    name: 'vulnerable_fire',
    effect_type: 'incoming_damage',
    description: 'Taking double damage from fire.',
    mechanics: { damage_type: 'fire', multiplier: 2.0 },
    stacking_behavior: 'ignore',
    is_buff: false,
    icon_name: 'flame'
  },
  {
    name: 'resistant_fire',
    effect_type: 'incoming_damage',
    description: 'Taking half damage from fire.',
    mechanics: { damage_type: 'fire', multiplier: 0.5 },
    stacking_behavior: 'ignore',
    is_buff: true,
    icon_name: 'shield-half'
  },
  {
    name: 'immune_fire',
    effect_type: 'incoming_damage',
    description: 'Immune to fire damage.',
    mechanics: { damage_type: 'fire', multiplier: 0.0 },
    stacking_behavior: 'ignore',
    is_buff: true,
    icon_name: 'shield-x'
  },

  # Healing modifier effects
  {
    name: 'healing_amplified',
    effect_type: 'healing',
    description: 'Receiving 50% more healing from all sources.',
    mechanics: { multiplier: 1.5 },
    stacking_behavior: 'refresh',
    is_buff: true,
    icon_name: 'heart-plus'
  },
  {
    name: 'healing_reduced',
    effect_type: 'healing',
    description: 'Receiving 50% less healing from all sources.',
    mechanics: { multiplier: 0.5 },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'heart-crack'
  },
  {
    name: 'healing_blocked',
    effect_type: 'healing',
    description: 'Cannot receive healing.',
    mechanics: { multiplier: 0.0 },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'heart-off'
  },

  # Grapple effects
  {
    name: 'grappled',
    effect_type: 'grapple',
    description: 'Being held by another combatant. Cannot move freely.',
    mechanics: { grappled_by_id: nil },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'hand-grab'
  },
  {
    name: 'grappling',
    effect_type: 'grapple',
    description: 'Holding another combatant in place.',
    mechanics: { grappling_id: nil },
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'hand-fist'
  },

  # Protection effects (prevents targeting)
  {
    name: 'sanctuary',
    effect_type: 'targeting_restriction',
    description: 'Protected from attack by a specific combatant.',
    mechanics: { cannot_target_id: nil },
    stacking_behavior: 'refresh',
    is_buff: true,
    icon_name: 'church'
  },

  # Snare effect (blocks movement)
  {
    name: 'snared',
    effect_type: 'movement',
    description: 'Cannot move.',
    mechanics: { can_move: false },
    modifier_value: 0,
    stacking_behavior: 'refresh',
    is_buff: false,
    icon_name: 'anchor'
  }
].freeze

puts 'Seeding combat status effects...'

EFFECTS.each do |effect_data|
  existing = StatusEffect.first(name: effect_data[:name])

  # Default cleansable to true for debuffs, false for buffs
  # Special cases: grapple effects are not cleansable (must break free)
  cleansable = if effect_data[:cleansable].nil?
                 effect_data[:is_buff] == false && effect_data[:effect_type] != 'grapple'
               else
                 effect_data[:cleansable]
               end

  if existing
    # Update existing effect
    existing.update(
      effect_type: effect_data[:effect_type],
      description: effect_data[:description],
      mechanics: Sequel.pg_json_wrap(effect_data[:mechanics]),
      stacking_behavior: effect_data[:stacking_behavior] || 'refresh',
      max_stacks: effect_data[:max_stacks] || 1,
      is_buff: effect_data[:is_buff],
      icon_name: effect_data[:icon_name],
      cleansable: cleansable
    )
    puts "  Updated: #{effect_data[:name]} (cleansable: #{cleansable})"
  else
    # Create new effect
    StatusEffect.create(
      name: effect_data[:name],
      effect_type: effect_data[:effect_type],
      description: effect_data[:description],
      mechanics: Sequel.pg_json_wrap(effect_data[:mechanics]),
      stacking_behavior: effect_data[:stacking_behavior] || 'refresh',
      max_stacks: effect_data[:max_stacks] || 1,
      is_buff: effect_data[:is_buff],
      icon_name: effect_data[:icon_name],
      cleansable: cleansable
    )
    puts "  Created: #{effect_data[:name]} (cleansable: #{cleansable})"
  end
end

puts "Done! Seeded #{EFFECTS.size} combat status effects."
