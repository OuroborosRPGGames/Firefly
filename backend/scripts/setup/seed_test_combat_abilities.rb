# frozen_string_literal: true

# Seeds test combat abilities covering all mechanics for multi-agent testing.
# Run with: bundle exec ruby scripts/setup/seed_test_combat_abilities.rb

require_relative '../../config/application'

# Test abilities covering all combat mechanics
# Column mappings:
# - ability_type: combat, utility, passive, social, crafting
# - action_type: main, tactical, free, passive, reaction
# - target_type: self, ally, enemy
# - base_damage_dice: dice notation (e.g., '2d6')
# - cooldown_seconds: cooldown in seconds
# - applied_status_effects: JSONB array of effects to apply
# - is_healing: true for healing abilities
ABILITIES = [
  # === BASIC DAMAGE ABILITIES ===
  {
    name: 'Fireball',
    description: 'Hurls a ball of fire at the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d6',
    damage_type: 'fire',
    cooldown_seconds: 0
  },
  {
    name: 'Frost Bolt',
    description: 'Fires a bolt of ice that slows the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d8',
    damage_type: 'ice',
    cooldown_seconds: 0,
    applied_status_effects: [{ name: 'slowed', duration: 2 }]
  },
  {
    name: 'Poison Strike',
    description: 'A venomous attack that poisons the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d6',
    damage_type: 'poison',
    cooldown_seconds: 0,
    applied_status_effects: [{ name: 'poisoned', duration: 3, stacks: 1 }]
  },
  {
    name: 'Rending Slash',
    description: 'A brutal slash that causes bleeding.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d4',
    damage_type: 'physical',
    cooldown_seconds: 0,
    applied_status_effects: [{ name: 'bleeding', duration: 3, stacks: 1 }]
  },
  {
    name: 'Ignite',
    description: 'Sets the target on fire.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d4',
    damage_type: 'fire',
    cooldown_seconds: 6,
    applied_status_effects: [{ name: 'burning', duration: 3 }]
  },

  # === AOE ABILITIES ===
  {
    name: 'Blizzard',
    description: 'A freezing storm that hits all in the area.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d6',
    damage_type: 'ice',
    cooldown_seconds: 18,
    aoe_shape: 'circle',
    aoe_radius: 2,
    applied_status_effects: [{ name: 'freezing', duration: 2 }]
  },
  {
    name: 'Flame Breath',
    description: 'Breathes fire in a cone.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d4',
    damage_type: 'fire',
    cooldown_seconds: 12,
    aoe_shape: 'cone',
    aoe_radius: 3
  },
  {
    name: 'Chain Lightning',
    description: 'Lightning that jumps between targets.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d6',
    damage_type: 'lightning',
    cooldown_seconds: 18,
    chain_config: { max_targets: 3, range_per_jump: 3, damage_falloff: 0.5, friendly_fire: false }
  },

  # === HEALING ABILITIES ===
  {
    name: 'Heal',
    description: 'Restores health to an ally.',
    ability_type: 'combat',
    target_type: 'ally',
    action_type: 'main',
    base_damage_dice: '2d6',
    damage_type: 'healing',
    is_healing: true,
    cooldown_seconds: 0
  },
  {
    name: 'Mass Heal',
    description: 'Heals all allies in an area.',
    ability_type: 'combat',
    target_type: 'ally',
    action_type: 'main',
    base_damage_dice: '1d6',
    damage_type: 'healing',
    is_healing: true,
    cooldown_seconds: 24,
    aoe_shape: 'circle',
    aoe_radius: 3
  },
  {
    name: 'Regeneration',
    description: 'Grants regenerating health over time.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'regenerating', duration: 5 }]
  },
  {
    name: 'Blessing',
    description: 'Divine favor grants healing over time.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'tactical',
    cooldown_seconds: 6,
    applied_status_effects: [{ name: 'blessed', duration: 4, stacks: 2 }]
  },

  # === BUFF ABILITIES ===
  {
    name: 'Empower',
    description: 'Increases the target damage output.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'empowered', duration: 3 }]
  },
  {
    name: 'Shield',
    description: 'Grants a protective shield.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'shielded', duration: 5, stacks: 3 }]
  },
  {
    name: 'Iron Skin',
    description: 'Reduces all incoming damage.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'protected', duration: 4 }]
  },
  {
    name: 'Fire Ward',
    description: 'Grants resistance to fire damage.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'tactical',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'resistant_fire', duration: 5 }]
  },
  {
    name: 'Fire Immunity',
    description: 'Grants temporary immunity to fire.',
    ability_type: 'utility',
    target_type: 'self',
    action_type: 'main',
    cooldown_seconds: 30,
    applied_status_effects: [{ name: 'immune_fire', duration: 3 }]
  },

  # === DEBUFF ABILITIES ===
  {
    name: 'Stun',
    description: 'Stuns the target, preventing actions.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'stunned', duration: 1 }]
  },
  {
    name: 'Daze',
    description: 'Dazes the target, blocking tactical actions.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'tactical',
    cooldown_seconds: 6,
    applied_status_effects: [{ name: 'dazed', duration: 2 }]
  },
  {
    name: 'Taunt',
    description: 'Forces the target to attack you.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'tactical',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'taunted', duration: 2 }]
  },
  {
    name: 'Terrify',
    description: 'Strikes fear into the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'frightened', duration: 2 }]
  },
  {
    name: 'Expose Weakness',
    description: 'Makes the target vulnerable to fire.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'tactical',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'vulnerable_fire', duration: 3 }]
  },

  # === MOVEMENT CONTROL ABILITIES ===
  {
    name: 'Entangle',
    description: 'Snares the target, preventing movement.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'snared', duration: 2 }]
  },
  {
    name: 'Immobilize',
    description: 'Completely immobilizes the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'immobilized', duration: 2 }]
  },
  {
    name: 'Slow',
    description: 'Slows the target movement.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'tactical',
    cooldown_seconds: 6,
    applied_status_effects: [{ name: 'slowed', duration: 3 }]
  },
  {
    name: 'Leg Sweep',
    description: 'Knocks the target prone.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d4',
    damage_type: 'physical',
    cooldown_seconds: 12,
    applies_prone: true,
    applied_status_effects: [{ name: 'prone', duration: 1 }]
  },

  # === FORCED MOVEMENT ABILITIES ===
  {
    name: 'Force Push',
    description: 'Pushes the target away.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d4',
    damage_type: 'physical',
    cooldown_seconds: 6,
    forced_movement: { type: 'push', distance: 3 }
  },
  {
    name: 'Grappling Hook',
    description: 'Pulls the target toward you.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d4',
    damage_type: 'physical',
    cooldown_seconds: 12,
    forced_movement: { type: 'pull', distance: 4 }
  },

  # === GRAPPLE ABILITIES ===
  {
    name: 'Grapple',
    description: 'Grabs and restrains the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'grappled', duration: 3 }]
  },

  # === SPECIAL MECHANIC ABILITIES ===
  {
    name: 'Vampiric Strike',
    description: 'Drains life from the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d4',
    damage_type: 'shadow',
    cooldown_seconds: 12,
    lifesteal_max: 10
  },
  {
    name: 'Soul Rend',
    description: 'True damage that bypasses all resistances.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d8',
    damage_type: 'shadow',
    cooldown_seconds: 18,
    bypasses_resistances: true
  },
  {
    name: 'Execute',
    description: 'Deals massive damage to low-health targets.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d6',
    damage_type: 'physical',
    cooldown_seconds: 24,
    execute_threshold: 25,
    execute_effect: { damage_multiplier: 3.0 }
  },
  {
    name: 'Pyroblast',
    description: 'Deals extra damage to burning targets.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '2d6',
    damage_type: 'fire',
    cooldown_seconds: 12,
    conditional_damage: [{ condition: 'target_has_effect', effect_name: 'burning', bonus_dice: '2d6' }]
  },

  # === HEALING MODIFIER ABILITIES ===
  {
    name: 'Healing Aura',
    description: 'Amplifies healing received by the target.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'healing_amplified', duration: 4 }]
  },
  {
    name: 'Curse of Withering',
    description: 'Reduces healing received by the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 12,
    applied_status_effects: [{ name: 'healing_reduced', duration: 4 }]
  },
  {
    name: 'Anti-Heal',
    description: 'Completely blocks healing on the target.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    cooldown_seconds: 24,
    applied_status_effects: [{ name: 'healing_blocked', duration: 2 }]
  },

  # === PROTECTION ABILITIES ===
  {
    name: 'Sanctuary',
    description: 'Protects ally from being attacked.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 18,
    applied_status_effects: [{ name: 'sanctuary', duration: 3 }]
  },

  # === CLEANSE ABILITIES ===
  {
    name: 'Purify',
    description: 'Removes all cleansable debuffs from the target.',
    ability_type: 'utility',
    target_type: 'ally',
    action_type: 'main',
    cooldown_seconds: 12,
    effects: { cleanses: true }
  },
  {
    name: 'Cleansing Flames',
    description: 'Burns away debuffs from yourself.',
    ability_type: 'utility',
    target_type: 'self',
    action_type: 'tactical',
    cooldown_seconds: 18,
    effects: { cleanses: true }
  },

  # === SACRIFICE ABILITIES ===
  {
    name: 'Blood Magic',
    description: 'Sacrifices HP to deal massive damage.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '4d6',
    damage_type: 'shadow',
    cooldown_seconds: 18,
    health_cost: 10
  },

  # === COMBO ABILITIES ===
  {
    name: 'Shatter',
    description: 'Deals extra damage to frozen targets.',
    ability_type: 'combat',
    target_type: 'enemy',
    action_type: 'main',
    base_damage_dice: '1d8',
    damage_type: 'physical',
    cooldown_seconds: 6,
    combo_condition: { requires_effect: 'freezing', bonus_dice: '3d6', consumes_effect: true }
  }
].freeze

puts 'Seeding test combat abilities...'

ABILITIES.each do |ability_data|
  existing = Ability.first(name: ability_data[:name])

  # Convert complex hashes to JSONB
  jsonb_fields = %i[chain_config forced_movement conditional_damage combo_condition applied_status_effects damage_types effects execute_effect]

  create_data = ability_data.dup
  jsonb_fields.each do |field|
    if create_data[field]
      create_data[field] = Sequel.pg_json_wrap(create_data[field])
    end
  end

  if existing
    existing.update(create_data)
    puts "  Updated: #{ability_data[:name]}"
  else
    Ability.create(create_data)
    puts "  Created: #{ability_data[:name]}"
  end
end

puts "Done! Seeded #{ABILITIES.size} test combat abilities."
