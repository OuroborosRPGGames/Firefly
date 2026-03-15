# frozen_string_literal: true

# Seeds for the Ability Builder System
# Creates status effects and example abilities

# Require the app to load models
require_relative '../../app'

puts "Seeding combat abilities and status effects..."

# === STATUS EFFECTS ===

# Snared - Can't move
snared = StatusEffect.first(name: 'snared') || StatusEffect.create(
  name: 'snared',
  effect_type: 'movement',
  description: 'Unable to move until the effect expires',
  mechanics: { 'can_move' => false },
  stacking_behavior: 'refresh',
  max_stacks: 1,
  is_buff: false,
  icon_name: 'snare'
)
puts "  Created/found status effect: #{snared.name}"

# Vulnerable - +5 incoming damage per attack
vulnerable = StatusEffect.first(name: 'vulnerable') || StatusEffect.create(
  name: 'vulnerable',
  effect_type: 'incoming_damage',
  description: 'Each incoming attack deals +5 additional damage',
  mechanics: { 'modifier' => 5 },
  stacking_behavior: 'stack',
  max_stacks: 3,
  is_buff: false,
  icon_name: 'vulnerability'
)
puts "  Created/found status effect: #{vulnerable.name}"

# Shielded - -5 incoming damage per attack
shielded = StatusEffect.first(name: 'shielded') || StatusEffect.create(
  name: 'shielded',
  effect_type: 'incoming_damage',
  description: 'Each incoming attack deals -5 less damage',
  mechanics: { 'modifier' => -5 },
  stacking_behavior: 'refresh',
  max_stacks: 1,
  is_buff: true,
  icon_name: 'shield'
)
puts "  Created/found status effect: #{shielded.name}"

# Empowered - +3 outgoing damage per attack
empowered = StatusEffect.first(name: 'empowered') || StatusEffect.create(
  name: 'empowered',
  effect_type: 'outgoing_damage',
  description: 'Each outgoing attack deals +3 additional damage',
  mechanics: { 'modifier' => 3 },
  stacking_behavior: 'stack',
  max_stacks: 3,
  is_buff: true,
  icon_name: 'empower'
)
puts "  Created/found status effect: #{empowered.name}"

puts "Status effects seeded!"

# === EXAMPLE ABILITIES ===

# Find or create a test universe
universe = Universe.first || Universe.create(name: 'Test Universe', description: 'For testing')
puts "Using universe: #{universe.name}"

# Fireball - Main action, enemy targeted, AoE circle
fireball = Ability.first(universe_id: universe.id, name: 'Fireball') || Ability.create(
  universe_id: universe.id,
  name: 'Fireball',
  ability_type: 'combat',
  action_type: 'main',
  target_type: 'enemy',
  activation_segment: 75,
  segment_variance: 2,
  aoe_shape: 'circle',
  aoe_radius: 1,
  base_damage_dice: '2d8',
  damage_stat: 'Intelligence',
  damage_type: 'fire',
  is_healing: false,
  costs: {
    'ability_penalty' => { 'amount' => -6, 'decay_per_round' => 2 }
  },
  applied_status_effects: [],
  cast_verbs: ['hurls a blazing fireball', 'conjures a sphere of flame', 'unleashes a fiery blast'],
  hit_verbs: ['engulfs', 'scorches', 'burns', 'sears'],
  aoe_descriptions: ['The flames spread to', 'The explosion catches', 'Fire licks at'],
  description: 'A classic fireball spell that deals AoE fire damage'
)
puts "  Created/found ability: #{fireball.name}"

# Ice Nova - Main action, self-centered AoE, applies snare
ice_nova = Ability.first(universe_id: universe.id, name: 'Ice Nova') || Ability.create(
  universe_id: universe.id,
  name: 'Ice Nova',
  ability_type: 'combat',
  action_type: 'main',
  target_type: 'self',
  activation_segment: 60,
  segment_variance: 3,
  aoe_shape: 'circle',
  aoe_radius: 2,
  base_damage_dice: '1d6',
  damage_stat: 'Intelligence',
  damage_type: 'ice',
  is_healing: false,
  costs: {
    'global_cooldown' => { 'rounds' => 2 }
  },
  applied_status_effects: [
    { 'effect' => 'snared', 'duration_rounds' => 1 }
  ],
  cast_verbs: ['unleashes a wave of frost', 'releases a freezing nova', 'emits a ring of ice'],
  hit_verbs: ['freezes', 'chills', 'frosts over', 'numbs'],
  aoe_descriptions: ['The cold spreads to', 'Ice crystals form on', 'Frost creeps across'],
  description: 'A self-centered ice explosion that snares nearby enemies'
)
puts "  Created/found ability: #{ice_nova.name}"

# Arcane Shield - Tactical action, self buff
arcane_shield = Ability.first(universe_id: universe.id, name: 'Arcane Shield') || Ability.create(
  universe_id: universe.id,
  name: 'Arcane Shield',
  ability_type: 'combat',
  action_type: 'tactical',
  target_type: 'self',
  activation_segment: 10,
  segment_variance: 1,
  aoe_shape: 'single',
  aoe_radius: 0,
  base_damage_dice: nil,
  damage_stat: nil,
  damage_type: nil,
  is_healing: false,
  costs: {
    'specific_cooldown' => { 'rounds' => 3 }
  },
  applied_status_effects: [
    { 'effect' => 'shielded', 'duration_rounds' => 2, 'value' => 5 }
  ],
  cast_verbs: ['conjures an arcane barrier', 'summons a protective ward', 'weaves a shield of magic'],
  hit_verbs: ['surrounds', 'envelops', 'protects'],
  aoe_descriptions: [],
  description: 'A tactical ability that provides temporary damage reduction'
)
puts "  Created/found ability: #{arcane_shield.name}"

# Weaken - Tactical action, applies vulnerable
weaken = Ability.first(universe_id: universe.id, name: 'Weaken') || Ability.create(
  universe_id: universe.id,
  name: 'Weaken',
  ability_type: 'combat',
  action_type: 'tactical',
  target_type: 'enemy',
  activation_segment: 30,
  segment_variance: 2,
  aoe_shape: 'single',
  aoe_radius: 0,
  base_damage_dice: nil,
  damage_stat: nil,
  damage_type: nil,
  is_healing: false,
  costs: {
    'specific_cooldown' => { 'rounds' => 2 }
  },
  applied_status_effects: [
    { 'effect' => 'vulnerable', 'duration_rounds' => 2, 'value' => 5 }
  ],
  cast_verbs: ['hexes', 'curses', 'marks with weakness'],
  hit_verbs: ['weakens', 'exposes', 'strips defenses from'],
  aoe_descriptions: [],
  description: 'A tactical ability that makes a target more vulnerable to damage'
)
puts "  Created/found ability: #{weaken.name}"

# Heal - Main action, ally targeted
heal = Ability.first(universe_id: universe.id, name: 'Heal') || Ability.create(
  universe_id: universe.id,
  name: 'Heal',
  ability_type: 'combat',
  action_type: 'main',
  target_type: 'ally',
  activation_segment: 40,
  segment_variance: 2,
  aoe_shape: 'single',
  aoe_radius: 0,
  base_damage_dice: '1d8+2',
  damage_stat: 'Intelligence',
  damage_type: 'healing',
  is_healing: true,
  costs: {
    'ability_penalty' => { 'amount' => -4, 'decay_per_round' => 2 }
  },
  applied_status_effects: [],
  cast_verbs: ['channels healing energy', 'calls upon restorative magic', 'weaves threads of life'],
  hit_verbs: ['mends', 'restores', 'heals', 'invigorates'],
  aoe_descriptions: [],
  description: 'A healing spell that restores HP to an ally'
)
puts "  Created/found ability: #{heal.name}"

# Lightning Bolt - Main action, line AoE
lightning_bolt = Ability.first(universe_id: universe.id, name: 'Lightning Bolt') || Ability.create(
  universe_id: universe.id,
  name: 'Lightning Bolt',
  ability_type: 'combat',
  action_type: 'main',
  target_type: 'enemy',
  activation_segment: 50,
  segment_variance: 5,
  aoe_shape: 'line',
  aoe_length: 5,
  aoe_radius: 0,
  base_damage_dice: '3d6',
  damage_stat: 'Intelligence',
  damage_type: 'lightning',
  is_healing: false,
  costs: {
    'ability_penalty' => { 'amount' => -8, 'decay_per_round' => 4 },
    'specific_cooldown' => { 'rounds' => 1 }
  },
  applied_status_effects: [],
  cast_verbs: ['unleashes a bolt of lightning', 'calls down thunder', 'channels electric fury'],
  hit_verbs: ['electrocutes', 'shocks', 'zaps', 'jolts'],
  aoe_descriptions: ['The lightning arcs to', 'Electricity jumps to', 'Thunder strikes'],
  description: 'A powerful lightning attack that strikes in a line'
)
puts "  Created/found ability: #{lightning_bolt.name}"

# Cone of Cold - Main action, cone AoE
cone_of_cold = Ability.first(universe_id: universe.id, name: 'Cone of Cold') || Ability.create(
  universe_id: universe.id,
  name: 'Cone of Cold',
  ability_type: 'combat',
  action_type: 'main',
  target_type: 'enemy',
  activation_segment: 65,
  segment_variance: 3,
  aoe_shape: 'cone',
  aoe_length: 4,
  aoe_angle: 60,
  aoe_radius: 0,
  base_damage_dice: '2d6',
  damage_stat: 'Intelligence',
  damage_type: 'ice',
  is_healing: false,
  costs: {
    'all_roll_penalty' => { 'amount' => -3, 'decay_per_round' => 1 }
  },
  applied_status_effects: [],
  cast_verbs: ['exhales a cone of frost', 'breathes icy death', 'sprays freezing mist'],
  hit_verbs: ['freezes', 'chills to the bone', 'numbs', 'frosts'],
  aoe_descriptions: ['The cold spreads to', 'Frost creeps over', 'Ice forms on'],
  description: 'A cone of freezing cold that damages multiple enemies'
)
puts "  Created/found ability: #{cone_of_cold.name}"

puts "\nAbilities seeded!"
puts "Total status effects: #{StatusEffect.count}"
puts "Total abilities: #{Ability.count}"
